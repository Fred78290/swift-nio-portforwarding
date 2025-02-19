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
    var eventLoop: EventLoop { get }
	
	func setChannel(_ channel: Channel)
	func bind() -> EventLoopFuture<Channel>
	func close() -> EventLoopFuture<Void>
}

extension PortForwarding {
	private static func Log(_ name: Self.Type) -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.\(name)")

		logger.logLevel = portForwarderLogLevel

		return logger
	}

	func bind() -> EventLoopFuture<Channel> {
		let server: EventLoopFuture<any Channel> = bootstrap.bind(to: self.bindAddress)

		server.whenComplete({ (result: Result<any Channel, Error>) in
			switch result {
			case let .success(channel):
				self.setChannel(channel)
				Self.Log(type(of: self)).info("Listening on \(String(describing: channel.localAddress))")
			case let .failure(error):
				Self.Log(type(of: self)).error("Failed to bind \(self.bindAddress), \(error)")
			}
		})

		return server
    }

    func close() -> EventLoopFuture<Void> {
		return self.eventLoop.flatSubmit {
			guard let channel = self.channel else {
				// The server wasn't created yet, so we can just shut down straight away and let the OS clean us up.
				return self.eventLoop.makeSucceededFuture(())
			}

			Self.Log(type(of: self)).info("Close on \(String(describing: channel.localAddress))")

			return channel.close()
		}
	}
}

public protocol Bindable {
	func bind(to address: SocketAddress) -> EventLoopFuture<Channel>
}
