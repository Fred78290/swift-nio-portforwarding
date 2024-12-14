import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix


final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Error in pipeline: \(error)")
        context.close(promise: nil)
    }
}

public typealias ChannelResults = [Result<Void, any Error>]

public class PortForwarder {
	let group: EventLoopGroup
	let bindAddress: String
	let mappedPorts: [MappedPort]
	let remoteHost: String
	let serverBootstrap: [PortForwarding]

	deinit {
		try? self.group.syncShutdownGracefully()
	}

	public init(group: EventLoopGroup, remoteHost: String, mappedPorts: [MappedPort], bindAddress: String = "127.0.0.1") throws {
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
					serverBootstrap.append(UDPPortForwardingServer(group: group, bindAddress: bindAddress, remoteAddress: remoteAddress))
				default:
					serverBootstrap.append(UDPPortForwardingServer(group: group, bindAddress: bindAddress, remoteAddress: remoteAddress))
			}

			return serverBootstrap
		}
	}

	public convenience init(remoteHost: String, mappedPorts: [MappedPort], bindAddress: String = "127.0.0.1") throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: mappedPorts.count)

		try self.init(group: group, remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "127.0.0.1")
	}

	public func close() -> EventLoopFuture<Void> {
		let closed = self.serverBootstrap.map { bootstrap in
			return bootstrap.close()
		}

		return EventLoopFuture.andAllComplete(closed, on: self.group.next())
	}

	public func bind() -> EventLoopFuture<ChannelResults>? {
		let binded = self.serverBootstrap.map { bootstrap in
			let result = bootstrap.bind()
			let logger: Logger = Logger(label: "com.aldunelabs.portforwarder.PortForwardingServer")

			result.whenComplete{ result in
				switch result {
				case .success:
					logger.info("PortForwarder success: forward: \(bootstrap.bindAddress) -> \(bootstrap.remoteAddress)")
				case .failure:
					let _ = result.mapError{
						logger.error("PortForwarder failed:forward: \(bootstrap.bindAddress) -> \(bootstrap.remoteAddress), reason: \($0)")
						
						return $0
					}
				}
			}

			return result
		}

		return EventLoopFuture.whenAllComplete(binded, on: self.group.next())
	}
}
