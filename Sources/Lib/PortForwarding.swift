import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

enum PortForwardingError: Error {
	case unimplementedProtocol
	case unsupportedProtocol(String)
	case alreadyBinded(String)
	case closePending
	case notFound(String)
}

public protocol PortForwarding: Equatable {
	var bootstrap: Bindable { get }
	var proto: MappedPort.Proto { get }
	var remoteAddress: SocketAddress { get }
	var bindAddress: SocketAddress { get }
	var channel: Channel? { get }
    var eventLoop: EventLoop { get }
	
	func setChannel(_ channel: Channel)
	func bind() -> EventLoopFuture<Channel>
	func close() -> EventLoopFuture<Void>
}

extension PortForwarding {
	public static func == (lhs: Self, rhs: Self) -> Bool {
		return lhs.bindAddress == rhs.bindAddress
			&& lhs.remoteAddress == rhs.remoteAddress
			&& lhs.proto == rhs.proto
	}
}

extension PortForwarding {
	public func bind() -> EventLoopFuture<Channel> {
		let server: EventLoopFuture<any Channel> = bootstrap.bind(to: self.bindAddress)

		server.whenComplete({ (result: Result<any Channel, Error>) in
			switch result {
			case let .success(channel):
				self.setChannel(channel)
				Log(self).info("Listening on \(String(describing: channel.localAddress))")
			case let .failure(error):
				Log(self).error("Failed to bind \(self.bindAddress), \(error)")
			}
		})

		return server
    }

    public func close() -> EventLoopFuture<Void> {
		self.eventLoop.makeFutureWithTask {
			guard let channel: any Channel = self.channel else {
				// The server wasn't created yet, so we can just shut down straight away and let the OS clean us up.
				return
			}

			Log(self).info("Close on \(String(describing: channel.localAddress))")

			return try await channel.close()
		}
	}
}

public protocol Bindable {
	func bind(to address: SocketAddress) -> EventLoopFuture<Channel>
}
