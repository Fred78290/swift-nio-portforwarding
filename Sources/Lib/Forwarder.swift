import Foundation
import Dispatch
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import Atomics
import NIOConcurrencyHelpers

extension SocketAddress {
	public struct UnixDomainSocketPathWrongType: Error {}

	static func cleanupUnixDomainSocket(atPath path: String) throws {
		do {
			var sb: stat = stat()
			var r = lstat(path, &sb)

			if r == -1 {
				throw IOError(errnoCode: errno, reason: "lstat failed")
			}

			// Only unlink the existing file if it is a socket
			if sb.st_mode & S_IFSOCK == S_IFSOCK {
				r = unlink(path)
				if r == -1 {
					throw IOError(errnoCode: errno, reason: "unlink failed")
				}
			} else {
				throw UnixDomainSocketPathWrongType()
			}
		} catch let err as IOError {
			// If the filepath did not exist, we consider it cleaned up
			if err.errnoCode == ENOENT {
				return
			}
			throw err
		}
	}

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

	public init(unixDomainSocketPath: String, cleanupExistingSocketFile: Bool) throws {
		try SocketAddress.cleanupUnixDomainSocket(atPath: unixDomainSocketPath)
		try self.init(unixDomainSocketPath: unixDomainSocketPath)
	}
}

public var portForwarderLogLevel = Logger.Level.info

func isDebugLog() -> Bool {
	return portForwarderLogLevel < Logger.Level.info
}

func Log(_ target: Any) -> Logger {
	let thisType = type(of: target)
	var logger = Logger(label: "com.aldunelabs.portforwarder.\(String(describing: thisType))")
	logger.logLevel = portForwarderLogLevel

	return logger
}

final class ErrorHandler: ChannelInboundHandler {
	typealias InboundIn = Any

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		print("Error in pipeline: \(error)")
		context.close(promise: nil)
	}
}

public typealias ChannelResults = [Result<Void, any Error>]

public class PortForwarderClosure: @unchecked Sendable {
	private var channels : [EventLoopFuture<Channel>]
	private let on: EventLoop
	private var closing: Bool = false
	private var closeFuture: EventLoopFuture<Void>
	private let promise: EventLoopPromise<Void>
	private let counter: ManagedAtomic<Int> = .init(0)
	private let semaphore: DispatchSemaphore = .init(value: 1)

	init(_ channels: [EventLoopFuture<Channel>], on: EventLoop) {
		self.channels = channels
		self.on = on
		self.promise = on.makePromise(of: Void.self)
		self.closeFuture = EventLoopFuture.andAllComplete(channels.map { $0.flatMap {  $0.closeFuture } }, on: on)

		self.whenCloseComplete()
	}

	private func whenCloseComplete() {
		self.counter.wrappingIncrement(ordering: .relaxed)

		self.closeFuture.whenComplete { _ in
			let counter: Int = self.counter.wrappingDecrementThenLoad(ordering: .relaxed)

			Log(self).info("Port forwarder closure: \(counter) channels left")

			if counter == 0 {
				self.closing = true
				self.promise.succeed()
			}
		}
	}

	public func appendChannel(_ channel: EventLoopFuture<Channel>) throws {
		if self.closing {
			throw PortForwardingError.closePending
		}

		self.semaphore.wait()

		defer {
			self.semaphore.signal()
		}

		self.channels.append(channel)
		self.closeFuture = self.closeFuture.flatMap {
			channel.flatMap {
				$0.closeFuture
			}
		}

		self.whenCloseComplete()
	}

	public func appendChannel(_ channels: [EventLoopFuture<Channel>]) throws {
		if self.closing {
			throw PortForwardingError.closePending
		}

		self.semaphore.wait()

		defer {
			self.semaphore.signal()
		}

		// Append the new channels to the port forwarder closure
		self.channels.append(contentsOf: channels)

		// Update the close future to include the new channels
		self.closeFuture = channels.reduce(self.closeFuture) { result, channel in
			result.flatMap {
				channel.flatMap {
					$0.closeFuture
				}
			}
		}

		self.whenCloseComplete()
	}

	public func get() async throws {
		try await self.promise.futureResult.get()
	}

	public func wait() throws {
		try self.promise.futureResult.wait()
	}
}

public typealias PortForwardings = [any PortForwarding]


extension PortForwardings {
	public func bind() -> [EventLoopFuture<Channel>] {
		self.map { $0.bind() }
	}
}

public class PortForwarder: @unchecked Sendable {
	internal let group: EventLoopGroup
	internal var shutdownGroup: Bool = false
	internal var serverBootstrap: [any PortForwarding] = []
	internal var portForwarderClosure: PortForwarderClosure? = nil

	private enum RunState {
		case running
		case closing([(DispatchQueue, ShutdownGracefullyCallback)])
		case closed(Error?)
	}

	private typealias ShutdownGracefullyCallback = (Error?) -> Void

	private let shutdownLock: NIOLock = NIOLock()
	private var runState: RunState = .running

	deinit {
		if shutdownGroup {
			try? self.group.syncShutdownGracefully()
		}
	}

	public init(group: EventLoopGroup, remoteAddress: SocketAddress, bindAddress: SocketAddress, proto: MappedPort.Proto, udpConnectionTTL: Int = 5) throws {
		self.group = group
		self.serverBootstrap = try self.createPortForwardingServer(on: group.next(), bindAddress: bindAddress, remoteAddress: remoteAddress, proto: proto, ttl: udpConnectionTTL)
	}

	public init(group: EventLoopGroup, remoteHost: String, mappedPorts: [MappedPort], bindAddresses: [String] = ["127.0.0.1", "::1"], udpConnectionTTL: Int = 5) throws {
		self.group = group

		try bindAddresses.forEach { bindAddress in
			try mappedPorts.forEach { mappedPort in
				self.serverBootstrap.append(contentsOf: try self.createPortForwardingServer(on: group.next(),
				                                                                            bindAddress: try SocketAddress.makeAddress("tcp://\(bindAddress):\(mappedPort.host)"),
				                                                                            remoteAddress: try SocketAddress.makeAddress("tcp://\(remoteHost):\(mappedPort.guest)"),
				                                                                            proto: mappedPort.proto,
				                                                                            ttl: udpConnectionTTL))
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

		self.shutdownGroup = true
	}

	@available(*, noasync, message: "this can end up blocking the calling thread", renamed: "shutdownGracefully()")
	public func syncShutdownGracefully() throws {
		try self._syncShutdownGracefully()
	}

	private func _syncShutdownGracefully() throws {
		let semaphore = DispatchSemaphore(value: 0)
		let error = NIOLockedValueBox<Error?>(nil)

		self.shutdownGracefully { shutdownError in
			if let shutdownError = shutdownError {
				error.withLockedValue {
					$0 = shutdownError
				}
			}
			semaphore.signal()
		}

		semaphore.wait()

		try error.withLockedValue { error in
			if let error = error {
				throw error
			}
		}
	}

	public func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void) {
		self._shutdownGracefully(queue: .global(), callback)
	}

	private func _shutdownGracefully(queue: DispatchQueue, _ handler: @escaping ShutdownGracefullyCallback) {
		let g = DispatchGroup()
		let q = DispatchQueue(label: "PortForwarder.shutdownGracefullyQueue", target: queue)
		let wasRunning: Bool = self.shutdownLock.withLock {
			// We need to check the current `runState` and react accordingly.
			switch self.runState {
			case .running:
				// If we are still running, we set the `runState` to `closing`,
				// so that potential future invocations know, that the shutdown
				// has already been initiaited.
				self.runState = .closing([])
				return true
			case .closing(var callbacks):
				// If we are currently closing, we need to register the `handler`
				// for invocation after the shutdown is completed.
				callbacks.append((q, handler))
				self.runState = .closing(callbacks)
				return false
			case .closed(let error):
				// If we are already closed, we can directly dispatch the `handler`
				q.async {
					handler(error)
				}
				return false
			}
		}

		// If the `runState` was not `running` when `shutdownGracefully` was called,
		// the shutdown has already been initiated and we have to return here.
		guard wasRunning else {
			return
		}

		let future = EventLoopFuture.andAllComplete(self.serverBootstrap.map { $0.close() }, on: self.group.next())

		future.whenComplete { result in
			var err : Error? = nil

			switch result {
			case .success:
				if isDebugLog() {
					Log(self).debug("Port forwarder closed")
				}
			case let .failure(error):
				Log(self).error("Failed to close port forwarder, \(error)")
				err = error
			}

			g.notify(queue: q) {
				let queueCallbackPairs = self.shutdownLock.withLock {
					switch self.runState {
					case .closed, .running:
						preconditionFailure("PortForwarder in illegal state when closing: \(self.runState)")
					case .closing(let callbacks):
						self.runState = .closed(err)
						return callbacks
					}
				}

				queue.async {
					handler(err)
				}

				for queueCallbackPair in queueCallbackPairs {
					queueCallbackPair.0.async {
						queueCallbackPair.1(err)
					}
				}
			}
		}
	}

	public func bind() throws -> PortForwarderClosure {
		guard case .running = self.runState else {
			throw PortForwardingError.closePending
		}

		guard let portForwarderClosure = self.portForwarderClosure else {
			self.portForwarderClosure = PortForwarderClosure(self.serverBootstrap.bind(), on: self.group.next())

			return self.portForwarderClosure!
		}

		return portForwarderClosure
	}

	public func removePortForwardingServer(bindAddress: SocketAddress, remoteAddress: SocketAddress, proto: MappedPort.Proto, ttl: Int) throws {
		let filter: (any PortForwarding) -> Bool = {
			if proto == .both {
				return $0.bindAddress == bindAddress && $0.remoteAddress == remoteAddress
			}

			return $0.proto == proto && $0.bindAddress == bindAddress && $0.remoteAddress == remoteAddress
		}
		// Check if the port forwarding exists
		let concerned = self.serverBootstrap.filter(filter)

		if concerned.isEmpty {
			throw PortForwardingError.notFound("Port forwarding not found for \(proto):\(bindAddress) -> \(remoteAddress)")
		}

		// Remove the port forwarding from the list
		self.serverBootstrap.removeAll(where: filter)
	}

	public func addPortForwardingServer(remoteHost: String, mappedPorts: [MappedPort], bindAddress: String, udpConnectionTTL: Int = 5) throws -> [any PortForwarding] {
		try self.addPortForwardingServer(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: [bindAddress], udpConnectionTTL: udpConnectionTTL)	
	}

	public func addPortForwardingServer(remoteHost: String, mappedPorts: [MappedPort], bindAddress: [String] = ["127.0.0.1", "::1"], udpConnectionTTL: Int = 5) throws -> [any PortForwarding] {
		guard case .running = self.runState else {
			throw PortForwardingError.closePending
		}

		let portForwarding = try bindAddress.reduce(into: [any PortForwarding]()) { partialResult, bindAddress in
			try mappedPorts.forEach { mappedPort in
				let bindAddress = try SocketAddress.makeAddress("tcp://\(bindAddress):\(mappedPort.host)")
				let remoteAddress = try SocketAddress.makeAddress("tcp://\(remoteHost):\(mappedPort.guest)")
				let filter: (any PortForwarding) -> Bool = {
					if mappedPort.proto == .both {
						return $0.bindAddress == bindAddress && $0.remoteAddress == remoteAddress
					}

					return $0.proto == mappedPort.proto && $0.bindAddress == bindAddress && $0.remoteAddress == remoteAddress
				}

				if self.serverBootstrap.first(where: filter) != nil {
					throw PortForwardingError.alreadyBinded("Port forwarding already exists for \(mappedPort.proto):\(bindAddress) -> \(remoteAddress)")
				}

				partialResult.append(contentsOf: try self.createPortForwardingServer(on: self.group.next(),
				                                                                     bindAddress: bindAddress,
				                                                                     remoteAddress: remoteAddress,
				                                                                     proto: mappedPort.proto,
				                                                                     ttl: udpConnectionTTL))
			}
		}

		self.serverBootstrap.append(contentsOf: portForwarding)

		if let portForwarderClosure = self.portForwarderClosure {
			// Append the new channels to the port forwarder closure
			try portForwarderClosure.appendChannel(portForwarding.bind())
		}

		return portForwarding
	}

	public func addPortForwardingServer(bindAddress: SocketAddress, remoteAddress: SocketAddress, proto: MappedPort.Proto, ttl: Int) throws -> [any PortForwarding] {
		guard case .running = self.runState else {
			throw PortForwardingError.closePending
		}

		let filter: (any PortForwarding) -> Bool = {
			if proto == .both {
				return $0.bindAddress == bindAddress && $0.remoteAddress == remoteAddress
			}

			return $0.proto == proto && $0.bindAddress == bindAddress && $0.remoteAddress == remoteAddress
		}

		if self.serverBootstrap.first(where: filter) != nil {
			throw PortForwardingError.alreadyBinded("Port forwarding already exists for \(proto):\(bindAddress) -> \(remoteAddress)")
		}

		let portForwarding = try self.createPortForwardingServer(on: self.group.next(), bindAddress: bindAddress, remoteAddress: remoteAddress, proto: proto, ttl: ttl)

		self.serverBootstrap.append(contentsOf: portForwarding)

		if let portForwarderClosure = self.portForwarderClosure {
			// Append the new channels to the port forwarder closure
			try portForwarderClosure.appendChannel(portForwarding.bind())
		}

		return portForwarding
	}

	public func createPortForwardingServer(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress, proto: MappedPort.Proto, ttl: Int) throws -> [any PortForwarding] {
		switch proto {
		case .tcp:
			return [try self.createTCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress)]
		case .both:
			return [
				try self.createTCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress),
				try self.createUDPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: ttl)
			]
		default:
			return [try self.createUDPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: ttl)]
		}
	}

	public func createTCPPortForwardingServer(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress) throws -> TCPPortForwardingServer {
		return TCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress)
	}

	public func createUDPPortForwardingServer(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress, ttl: Int) throws -> UDPPortForwardingServer {
		return UDPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress, ttl: ttl)
	}
}
