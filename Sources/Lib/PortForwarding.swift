import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public enum PortForwardingError: Error {
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
				Log(self).debug("Listening on \(String(describing: channel.localAddress))")
			case let .failure(error):
				Log(self).error("Failed to bind \(self.bindAddress), \(error)")
			}
		})

		return server
	}

	public func close() -> EventLoopFuture<Void> {
		guard let channel: any Channel = self.channel else {
			// The server wasn't created yet, so we can just shut down straight away and let the OS clean us up.
			return self.eventLoop.makeSucceededVoidFuture()
		}

		Log(self).debug("Close on \(String(describing: channel.localAddress))")

		let c = channel.close()

		c.whenComplete { result in
			switch result {
			case .success:
				Log(self).debug("Closed on \(String(describing: channel.localAddress))")
			case let .failure(error):
				Log(self).error("Failed to close \(String(describing: channel.localAddress)), \(error)")
			}
		}

		return c
	}
}

public protocol Bindable {
	func bind(to address: SocketAddress) -> EventLoopFuture<Channel>
}
