import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

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

	init(_ channels: [EventLoopFuture<Channel>], on: EventLoop) {
		self.channels = channels
		self.on = on
	}

	public func get() async throws {
		let closing = self.channels.map { future in
			future.flatMap { channel in
				channel.closeFuture
			}
		}

		try await EventLoopFuture.andAllComplete(closing, on: on).get()
	}

	public func wait() throws {
		let closing = self.channels.map { future in
			future.flatMap { channel in
				channel.closeFuture
			}
		}

		try EventLoopFuture.andAllComplete(closing, on: on).wait()
	}
}

public class PortForwarder {
	let group: EventLoopGroup
	let bindAddress: String
	let mappedPorts: [MappedPort]
	let remoteHost: String
	let serverBootstrap: [PortForwarding]

	private static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.PortForwardingServer")

		logger.logLevel = portForwarderLogLevel

		return logger
	}

	deinit {
		try? self.group.syncShutdownGracefully()
	}

	public init(group: EventLoopGroup, remoteHost: String, mappedPorts: [MappedPort], bindAddresses: [String] = ["127.0.0.1", "::1"], udpConnectionTTL: Int = 5) {
		self.remoteHost = remoteHost
		self.mappedPorts = mappedPorts
		self.bindAddress = bindAddress
		self.group = group
		
		self.serverBootstrap = mappedPorts.reduce([]) { serverBootstrap, mappedPort in
			var serverBootstrap = serverBootstrap
			let bindAddress = try! SocketAddress.makeAddressResolvingHost(bindAddress, port: mappedPort.host)
			let remoteAddress = try! SocketAddress.makeAddressResolvingHost(remoteHost, port: mappedPort.guest)

			switch mappedPort.proto {
				case .tcp:
					serverBootstrap.append(TCPPortForwardingServer(group: group, bindAddress: bindAddress, remoteAddress: remoteAddress))
				case .both:
					serverBootstrap.append(TCPPortForwardingServer(group: group, bindAddress: bindAddress, remoteAddress: remoteAddress))
					serverBootstrap.append(UDPPortForwardingServer(group: group, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: udpConnectionTTL))
				default:
					serverBootstrap.append(UDPPortForwardingServer(group: group, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: udpConnectionTTL))
			}

			return serverBootstrap
		}
	}

	public convenience init(group: EventLoopGroup, remoteHost: String, mappedPorts: [MappedPort], bindAddress: String = "127.0.0.1", udpConnectionTTL: Int = 5) {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: mappedPorts.count)

		self.init(group: group, remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: bindAddress, udpConnectionTTL: udpConnectionTTL)
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
}
