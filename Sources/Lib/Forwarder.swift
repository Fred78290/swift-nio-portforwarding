import Foundation
import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

extension SocketAddress {
	public static func makeAddress(_ remoteAddress: String) throws -> SocketAddress {
		let socketAddress: SocketAddress

		guard let u = URL(string: remoteAddress) else {
			throw PortForwardingError.unsupportedProtocol("Invalid remote address \(remoteAddress)")
		}

		if u.scheme == "unix" || u.isFileURL {
			socketAddress = try .init(unixDomainSocketPath: u.path)
		} else {
			socketAddress = try self.makeAddressResolvingHost(u.host!, port: u.port ?? 0)
		}

		return socketAddress
	}
}

public var portForwarderLogLevel = Logger.Level.info

func isDebugLog() -> Bool {
	return portForwarderLogLevel < Logger.Level.info
}

final class ErrorHandler: ChannelInboundHandler {
	typealias InboundIn = Any

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		print("Error in pipeline: \(error)")
		context.close(promise: nil)
	}
}

public typealias ChannelResults = [Result<Void, any Error>]

public struct PortForwarderClosure {
	let channels : [EventLoopFuture<Channel>]
	private let on: EventLoop

	public var closeFuture: EventLoopFuture<Void> {
		get {
			return EventLoopFuture.andAllComplete(self.channels.map { future in
				future.flatMap { channel in
					channel.closeFuture
				}
			}, on: on)
		}
	}

	init(_ channels: [EventLoopFuture<Channel>], on: EventLoop) {
		self.channels = channels
		self.on = on
	}

	public func get() async throws {
		try await self.closeFuture.get()
	}

	public func wait() throws {
		try self.closeFuture.wait()
	}
}

public class PortForwarder {
	internal let group: EventLoopGroup
	internal var serverBootstrap: [PortForwarding] = []

	internal static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.PortForwardingServer")

		logger.logLevel = portForwarderLogLevel

		return logger
	}

	deinit {
		try? self.group.syncShutdownGracefully()
	}

	public init(group: EventLoopGroup, remoteAddress: SocketAddress, bindAddress: SocketAddress, proto: MappedPort.Proto, udpConnectionTTL: Int = 5) throws {
		self.group = group

		self.createPortForwardingServer(on: group.next(), bindAddress: bindAddress, remoteAddress: remoteAddress, proto: proto, ttl: udpConnectionTTL)
	}

	public init(group: EventLoopGroup, remoteHost: String, mappedPorts: [MappedPort], bindAddresses: [String] = ["127.0.0.1", "::1"], udpConnectionTTL: Int = 5) throws {
		self.group = group

		try bindAddresses.forEach { bindAddress in
			try mappedPorts.forEach { mappedPort in
				self.createPortForwardingServer(on: group.next(),
				                                bindAddress: try SocketAddress.makeAddress("tcp://\(bindAddress):\(mappedPort.host)"),
				                                remoteAddress: try SocketAddress.makeAddress("tcp://\(remoteHost):\(mappedPort.guest)"),
				                                proto: mappedPort.proto,
				                                ttl: udpConnectionTTL)
			}
		}
	}

	public convenience init(group: EventLoopGroup, remoteHost: String, mappedPorts: [MappedPort], bindAddress: String = "127.0.0.1", udpConnectionTTL: Int = 5) throws {
		try self.init(group: group, remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddresses: [bindAddress], udpConnectionTTL: udpConnectionTTL)
	}

	public convenience init(remoteHost: String, mappedPorts: [MappedPort], bindAddresses: [String] = ["127.0.0.1", "::1"], udpConnectionTTL: Int = 5) throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: mappedPorts.count)

		try self.init(group: group, remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddresses: bindAddresses, udpConnectionTTL: udpConnectionTTL)
	}

	public convenience init(remoteHost: String, mappedPorts: [MappedPort], bindAddress: String = "127.0.0.1", udpConnectionTTL: Int = 5) throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: mappedPorts.count)

		try self.init(group: group, remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddresses: [bindAddress], udpConnectionTTL: udpConnectionTTL)
	}

	public func syncShutdownGracefully() throws {
		let closed = self.serverBootstrap.map { bootstrap in
			return bootstrap.close()
		}

		try EventLoopFuture.andAllComplete(closed, on: self.group.next()).wait()
	}

	public func shutdownGracefully() async throws {
		let closed = self.serverBootstrap.map { bootstrap in
			return bootstrap.close()
		}

		try await EventLoopFuture.andAllComplete(closed, on: self.group.next()).get()
	}

	public func bind() -> PortForwarderClosure {

		let channels = self.serverBootstrap.map { bootstrap in
			let result = bootstrap.bind()

			result.whenComplete{ result in
				switch result {
				case .success:
					Self.Log().info("\(type(of: bootstrap)): bind complete: \(bootstrap.bindAddress) -> \(bootstrap.remoteAddress)")
				case .failure:
					let _ = result.mapError{
						Self.Log().error("\(type(of: bootstrap)): bind failed: \(bootstrap.bindAddress) -> \(bootstrap.remoteAddress), reason: \($0)")

						return $0
					}
				}
			}

			return result
		}

		return PortForwarderClosure(channels, on: self.group.next())
	}

	public func createPortForwardingServer(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress, proto: MappedPort.Proto, ttl: Int) {
		switch proto {
		case .tcp:
			serverBootstrap.append(self.createTCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress))
		case .both:
			serverBootstrap.append(self.createTCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress))
			serverBootstrap.append(self.createUDPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: ttl))
		default:
			serverBootstrap.append(self.createUDPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: ttl))
		}
	}

	public func createTCPPortForwardingServer(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress) -> TCPPortForwardingServer {
		return TCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress)
	}

	public func createUDPPortForwardingServer(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress, ttl: Int) -> UDPPortForwardingServer {
		return UDPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: ttl)
	}
}
