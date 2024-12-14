import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

enum PortForwardingError: Error {
	case unimplementedProtocol
}

public protocol PortForwarding {
	var bootstrap: Bindable { get }
	var remoteAddress: SocketAddress { get }
	var bindAddress: SocketAddress { get }
	var channel: Channel? { get }
    var serverLoop: EventLoop { get }
    var group: EventLoopGroup { get }
	
	func setChannel(_ channel: Channel)
	func bind() -> EventLoopFuture<Void>
	func close() -> EventLoopFuture<Void>
}

extension PortForwarding {
	func bind() -> NIOCore.EventLoopFuture<Void> {
		let server: EventLoopFuture<any Channel> = bootstrap.bind(to: self.bindAddress)

		server.whenComplete({ (result: Result<any Channel, Error>) in
			let logger = Logger(label: "com.aldunelabs.portforwarder.PortForwarding")

			switch result {
			case let .success(channel):
				logger.info("Listening on \(String(describing: channel.localAddress))")
			case let .failure(error):
				logger.error("Failed to bind \(self.bindAddress), \(error)")
			}
		})

		return server.flatMap {
			self.setChannel($0)
			return $0.closeFuture
		}
    }

    func close() -> EventLoopFuture<Void> {
		return self.serverLoop.flatSubmit {
			guard let channel = self.channel else {
				// The server wasn't created yet, so we can just shut down straight away and let the OS clean us up.
				return self.serverLoop.makeSucceededFuture(())
			}

			return channel.close()
		}
	}
}

public protocol Bindable {
	func bind(to address: SocketAddress) -> EventLoopFuture<Channel>
}
