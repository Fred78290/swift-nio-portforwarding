import XCTest
import Logging

@testable import NIOPortForwarding
@testable import NIOCore
@testable import NIOPosix

func Log(label: String) -> Logger {
	Logger(label: label)
}

extension Channel {
	func syncCloseAcceptingAlreadyClosed() throws {
		do {
			try self.close().wait()
		} catch ChannelError.alreadyClosed {
			// we're happy with this one
		} catch let e {
			throw e
		}
	}
}

func asyncAssertNoThrowWithValue<T>(
	_ body: @autoclosure () async throws -> T,
	defaultValue: T? = nil,
	message: String? = nil,
	file: StaticString = #filePath,
	line: UInt = #line
) async throws -> T {
	do {
		return try await body()
	} catch {
		XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
		if let defaultValue = defaultValue {
			return defaultValue
		} else {
			throw error
		}
	}
}

func assertNoThrowWithValue<T>(
	_ body: @autoclosure () throws -> T,
	defaultValue: T? = nil,
	message: String? = nil,
	file: StaticString = #filePath,
	line: UInt = #line
) throws -> T {
	do {
		return try body()
	} catch {
		XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
		if let defaultValue = defaultValue {
			return defaultValue
		} else {
			throw error
		}
	}
}

private final class ServerEchoHandler: ChannelInboundHandler {
	public typealias InboundIn = ByteBuffer
	public typealias OutboundOut = ByteBuffer

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var unwrappedInboundData = Self.unwrapInboundIn(data)
		var byteBuffer = ByteBuffer()

		byteBuffer.writeBuffer(&unwrappedInboundData)

		Log(label: "ServerEchoHandler").info("read channel, from: \(String(describing: context.remoteAddress)), content: \(String(buffer: byteBuffer))")

		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.writeAndFlush(data, promise: nil)
	}

	public func channelReadComplete(context: ChannelHandlerContext) {
		Log(label: "ServerEchoHandler").info("server read complete")
		context.flush()
		context.close(promise: nil)
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Log(label: "ServerEchoHandler").error("Caught error: \(error.localizedDescription)")

		context.fireErrorCaught(error)
		//context.close(promise: nil)
	}
}

private final class ClientEchoHandler: ChannelInboundHandler {
	public typealias InboundIn = ByteBuffer
	public typealias OutboundOut = ByteBuffer
	private var numBytes = 0

	private let remoteAddress: SocketAddress
	private var received: String
	private var receiveBuffer: ByteBuffer = ByteBuffer()

	init(remoteAddress: SocketAddress) {
		self.remoteAddress = remoteAddress
		self.received = ""
	}

	public func channelActive(context: ChannelHandlerContext) {
		// Channel is available. It's time to send the message to the server to initialize the ping-pong sequence.
		Log(label: "ClientEchoHandler").info("Send message: \(message) to \(remoteAddress)")

		// Set the transmission data.
		let buffer = context.channel.allocator.buffer(string: message)
		self.numBytes = buffer.readableBytes

		// Forward the data.
		context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
	}

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var unwrappedInboundData = Self.unwrapInboundIn(data)
		let logger = Log(label: "ClientEchoHandler")

		self.numBytes -= unwrappedInboundData.readableBytes
		self.receiveBuffer.writeBuffer(&unwrappedInboundData)

		logger.info("Received: '\(String(buffer: self.receiveBuffer))' back from the server.")

		if self.numBytes <= 0 {
			self.received = String(buffer: self.receiveBuffer)
		}
	}

	public func channelReadComplete(context: ChannelHandlerContext) {
		let logger = Log(label: "ClientEchoHandler")

		context.flush()

		if self.received == message {
			logger.info("client read complete, success")
			context.close(promise: nil)
		} else {
			logger.error("client read complete, failed")
			let _: EventLoopFuture<Void> = context.eventLoop.makeFailedFuture(EchoingError.mismatchMessage)
		}
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Log(label: "ClientEchoHandler").error("Caught error: \(error.localizedDescription)")

		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		//context.close(promise: nil)
		context.fireErrorCaught(error)
	}
}

struct TcpHelper {
	let group: EventLoopGroup

	func setupEchoClient(to address: SocketAddress) -> EventLoopFuture<any Channel> {
		let echoClient = ClientBootstrap(group: group.next())
			// Enable SO_REUSEADDR.
			.channelOption(.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { channel in
				channel.pipeline.addHandler(ClientEchoHandler(remoteAddress: address))
			}

		let client = echoClient.connect(to: address)

		client.whenComplete { result in
			switch result {
			case let .success(channel):
				Log(label: "TCPForwardingTests").info("client complete successed: \(String(describing: channel.localAddress))")
			case let .failure(error):
				Log(label: "TCPForwardingTests").info("client complete failed: \(error.localizedDescription)")
			}
		}

		return client
	}

	func setupEchoClient(host: String, serverPort: Int) throws -> EventLoopFuture<any Channel> {
		Log(label: "TCPForwardingTests").info("Setup client: \(host), server: \(serverPort)")

		return self.setupEchoClient(to: try SocketAddress.makeAddressResolvingHost(host, port: serverPort))
	}

	func setupEchoServer(to address: SocketAddress) -> EventLoopFuture<any Channel> {
		let echoServer = ServerBootstrap(group: group.next())
			// Enable SO_REUSEADDR.
			.serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
			.childChannelOption(.socketOption(.so_reuseaddr), value: 1)
			.childChannelOption(.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
			.childChannelInitializer { channel in
				channel.pipeline.addHandler(ServerEchoHandler())
			}

		let server: EventLoopFuture<any Channel> = echoServer.bind(to: address)

		server.whenComplete { result in
			switch result {
			case let .success(channel):
				Log(label: "TCPForwardingTests").info("server complete successed: \(String(describing: channel.localAddress))")
			case let .failure(error):
				Log(label: "TCPForwardingTests").info("server complete failed: \(error.localizedDescription)")
			}
		}

		return server
	}

	func setupEchoServer(host: String, port: Int) throws -> EventLoopFuture<any Channel> {
		Log(label: "TCPForwardingTests").info("Setup server: \(host), listen: \(port)")

		return self.setupEchoServer(to: try SocketAddress.makeAddressResolvingHost(host, port: port))
	}
}

final class TCPForwardingTests: XCTestCase {
	let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

	override class func setUp() {
		super.setUp()
		portForwarderLogLevel = Logger.Level.debug
	}

	deinit {
		try! group.syncShutdownGracefully()
	}

	func setupForwarder(remoteAddress: SocketAddress, bindAddress: SocketAddress) throws -> PortForwarder {
		return try PortForwarder(group: self.group, remoteAddress: remoteAddress, bindAddress: bindAddress, proto: .tcp)
	}

	func setupForwarder(host: String, port: Int, guest: Int) throws -> PortForwarder {
		Log(label: "TCPForwardingTests").info("Setup forwarder: \(host), port: \(port), guest: \(guest)")

		let portForwarder = try PortForwarder(group: self.group,
		                                      remoteHost: host,
		                                      mappedPorts: [MappedPort(host: port, guest: guest, proto: .tcp)],
		                                      bindAddress: host)

		return portForwarder
	}

	func testTCPEchoDirect() async throws {
		let helper = TcpHelper(group: group)
		let remoteAddress = try SocketAddress(unixDomainSocketPath: "/tmp/echo.sock", cleanupExistingSocketFile: true)
		let server = try assertNoThrowWithValue(helper.setupEchoServer(to: remoteAddress).wait())
		let client = try assertNoThrowWithValue(helper.setupEchoClient(to: remoteAddress).wait())

		defer {
			XCTAssertNoThrow(try server.syncCloseAcceptingAlreadyClosed())
		}

		try assertNoThrowWithValue(client.closeFuture.wait())
	}

	func testTCPEchoDirectWithUnixSocket() async throws {
		let helper = TcpHelper(group: group)
		let server = try assertNoThrowWithValue(helper.setupEchoServer(host: defaultEchoHost, port: defaultServerPort).wait())
		let client = try assertNoThrowWithValue(helper.setupEchoClient(host: defaultEchoHost, serverPort: defaultServerPort).wait())

		defer {
			XCTAssertNoThrow(try server.syncCloseAcceptingAlreadyClosed())
		}

		try assertNoThrowWithValue(client.closeFuture.wait())
	}

	func testTCPEchoForwarding() async throws {
		let helper = TcpHelper(group: group)
		let forwarder = try self.setupForwarder(host: defaultEchoHost, port: defaultForwardPort, guest: defaultServerPort)

		_ = try assertNoThrowWithValue(forwarder.bind())

		defer {
			XCTAssertNoThrow(try forwarder.syncShutdownGracefully())
		}

		let server = try assertNoThrowWithValue(helper.setupEchoServer(host: defaultEchoHost, port: defaultServerPort).wait())
		let client = try assertNoThrowWithValue(helper.setupEchoClient(host: defaultEchoHost, serverPort: defaultForwardPort).wait())

		defer {
			XCTAssertNoThrow(try server.syncCloseAcceptingAlreadyClosed())
		}

		try assertNoThrowWithValue(client.closeFuture.wait())
	}

	func testTCPEchoForwardingWithUnixSocket() async throws {
		let helper = TcpHelper(group: group)
		let remoteAddress = try SocketAddress(unixDomainSocketPath: "/tmp/echo.sock", cleanupExistingSocketFile: true)
		let bindAddress = try SocketAddress(unixDomainSocketPath: "/tmp/echo.sock.bind", cleanupExistingSocketFile: true)
		let forwarder = try self.setupForwarder(remoteAddress: remoteAddress, bindAddress: bindAddress)

		_ = try assertNoThrowWithValue(forwarder.bind())

		defer {
			XCTAssertNoThrow(try forwarder.syncShutdownGracefully())
		}

		let server = try assertNoThrowWithValue(helper.setupEchoServer(to: remoteAddress).wait())
		let client = try assertNoThrowWithValue(helper.setupEchoClient(to: bindAddress).wait())

		defer {
			XCTAssertNoThrow(try server.syncCloseAcceptingAlreadyClosed())
		}

		try assertNoThrowWithValue(client.closeFuture.wait())
	}

	func testTCPEchoForwardingByAddingForward() async throws {
		let forwarder = try assertNoThrowWithValue(PortForwarder(group: self.group,
		                                                         remoteHost: "www.google.com",
		                                                         mappedPorts: [
		                                                         	MappedPort(host: 1443, guest: 443, proto: .tcp),
		                                                         	MappedPort(host: 8080, guest: 80, proto: .tcp)],
		                                                         bindAddress: "127.0.0.1"))

		let portForwarderClosure = try assertNoThrowWithValue(forwarder.bind())
		let eventLoop = self.group.next()

		eventLoop.scheduleTask(in: .seconds(1)) {
			XCTAssertNoThrow(try forwarder.addPortForwardingServer(remoteHost: "www.apple.com",
			                                                       mappedPorts: [
			                                                       	MappedPort(host: 4443, guest: 443, proto: .tcp),
			                                                       	MappedPort(host: 8081, guest: 80, proto: .tcp)],
			                                                       bindAddress: "127.0.0.1"))
		}

		eventLoop.scheduleTask(in: .seconds(5)) {
			forwarder.shutdownGracefully { _ in
				Log(label: "testTCPEchoForwardingByAddingForward").info("shutdownGracefully")
				// Do nothing
			}
		}

		try await asyncAssertNoThrowWithValue(try await portForwarderClosure.get())
	}

	func testTCPEchoForwardingByAddingForwardAfterClose() async throws {
		let forwarder = try assertNoThrowWithValue(PortForwarder(group: self.group,
		                                                         remoteHost: "www.google.com",
		                                                         mappedPorts: [
		                                                         	MappedPort(host: 1443, guest: 443, proto: .tcp),
		                                                         	MappedPort(host: 8080, guest: 80, proto: .tcp)],
		                                                         bindAddress: "127.0.0.1"))

		let portForwarderClosure = try assertNoThrowWithValue(forwarder.bind())
		let eventLoop = self.group.next()

		eventLoop.scheduleTask(in: .seconds(2)) {
			forwarder.shutdownGracefully { _ in
				Log(label: "testTCPEchoForwardingByAddingForwardAfterClose").info("shutdownGracefully")
			}
		}

		try await asyncAssertNoThrowWithValue(try await portForwarderClosure.get())

		XCTAssertThrowsError(try forwarder.addPortForwardingServer(remoteHost: "www.apple.com",
		                                                           mappedPorts: [
		                                                           	MappedPort(host: 4443, guest: 443, proto: .tcp),
		                                                           	MappedPort(host: 8081, guest: 80, proto: .tcp)],
		                                                           bindAddress: "127.0.0.1"))
	}
}
