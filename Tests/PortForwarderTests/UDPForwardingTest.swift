import XCTest
import Logging

@testable import NIOPortForwarding
@testable import NIOCore
@testable import NIOPosix

let defaultServerPort: Int = 9999
let defaultClientPort: Int = 8888
let defaultForwardPort: Int = 19999
let defaultEchoHost: String = "127.0.0.1"
let message = "some random words"
enum EchoingError: Error {
	case mismatchMessage
	case internalError
}

private final class ServerEchoHandler: ChannelInboundHandler {
	public typealias InboundIn = AddressedEnvelope<ByteBuffer>
	public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

	private let logger = Logger(label: "ServerEchoHandler")

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let envelope = Self.unwrapInboundIn(data)
		let byteBuffer = envelope.data

		self.logger.info("read channel, from: \(envelope.remoteAddress), content: \(String(buffer: byteBuffer))")

		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.writeAndFlush(data, promise: context.eventLoop.makePromise(of: Void.self))
	}

	public func channelReadComplete(context: ChannelHandlerContext) {
		self.logger.info("channelReadComplete")

		context.close(promise: nil)
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		self.logger.error("Caught error: \(error.localizedDescription)")

		context.close(promise: nil)
	}
}

private final class ClientEchoHandler: ChannelInboundHandler {
	public typealias InboundIn = AddressedEnvelope<ByteBuffer>
	public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
	private var numBytes = 0

	private let remoteAddress: SocketAddress
	private let logger = Logger(label: "ClientEchoHandler")
	private var received: String

	init(remoteAddress: SocketAddress) {
		self.remoteAddress = remoteAddress
		self.received = ""
	}

	public func channelActive(context: ChannelHandlerContext) {
		// Channel is available. It's time to send the message to the server to initialize the ping-pong sequence.
		self.logger.info("Send message: \(message) to \(remoteAddress)")

		// Set the transmission data.
		let buffer = context.channel.allocator.buffer(string: message)
		self.numBytes = buffer.readableBytes

		// Forward the data.
		let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)

		context.writeAndFlush(Self.wrapOutboundOut(envelope), promise: nil)
	}

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let envelope = Self.unwrapInboundIn(data)
		let byteBuffer = envelope.data

		self.logger.info("read channel")

		self.numBytes -= byteBuffer.readableBytes

		if self.numBytes <= 0 {
			self.received = String(buffer: byteBuffer)

			self.logger.info("Received: '\(self.received)' back from the server, closing channel.")
		}
	}

	public func channelReadComplete(context: ChannelHandlerContext) {
		self.logger.info("channelReadComplete")

		if self.received == message {
			context.close(promise: nil)
		} else {
			let _: EventLoopFuture<Void> = context.eventLoop.makeFailedFuture(EchoingError.mismatchMessage)
		}
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		self.logger.error("Caught error: \(error.localizedDescription)")

		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.close(promise: nil)
	}
}

final class UDPForwardingTests: XCTestCase {
	let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	private let logger = Logger(label: "UDPForwardingTests")
	var echoServer: DatagramBootstrap?
	var echoClient: DatagramBootstrap?
	var portForwarder: PortForwarder?

	deinit {
		try! group.syncShutdownGracefully()
	}

	func setupEchoClient(host: String, serverPort: Int, clientPort: Int) -> EventLoopFuture<ChannelResults> {
		self.logger.info("Setup client: \(host), server: \(serverPort), client: \(clientPort)")

		let echoClient = DatagramBootstrap(group: group.next())
			// Enable SO_REUSEADDR.
			.channelOption(.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { channel in
				channel.pipeline.addHandler(ClientEchoHandler(remoteAddress: try! SocketAddress.makeAddressResolvingHost(host, port: serverPort)))
			}

		self.echoClient = echoClient

		let client = echoClient.bind(host: host, port: clientPort)

		return EventLoopFuture.whenAllComplete([client.flatMap {
					let channel = $0
					self.logger.info("client complete \(String(describing: channel.localAddress))")
					return channel.closeFuture
				}], on: self.group.next())
	}

	func setupEchoServer(host: String, port: Int) -> EventLoopFuture<ChannelResults> {
		self.logger.info("Setup server: \(host), listen: \(port)")

		let echoServer = DatagramBootstrap(group: group.next())
			// Enable SO_REUSEADDR.
			.channelOption(.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { channel in
				channel.pipeline.addHandler(ServerEchoHandler())
			}

		self.echoServer = echoServer

		let server = echoServer.bind(host: host, port: port)

		return EventLoopFuture.whenAllComplete([server.flatMap {
					let channel = $0
					self.logger.info("server complete \(String(describing: channel.localAddress))")
					return channel.closeFuture
				}], on: self.group.next())
	}

	func setupForwarder(host: String, port: Int, guest: Int) -> EventLoopFuture<ChannelResults> {
		self.logger.info("Setup forwarder: \(host), port: \(port), guest: \(guest)")

		let portForwarder = try! PortForwarder(group: self.group.next(),
						remoteHost: host,
						mappedPorts: [MappedPort(host: port, guest: guest, proto: .udp)],
						bindAddress: host)

		self.portForwarder = portForwarder

		return portForwarder.bind()!
	}

	func testUDPEchoDirect() async throws {
		try await withThrowingTaskGroup(of: EventLoopFuture<ChannelResults>.self) { group in 
			group.addTask {
				self.setupEchoServer(host: defaultEchoHost, port: defaultServerPort)
			}

            try await Task.sleep(nanoseconds: 100_000_000)

			group.addTask {
				self.setupEchoClient(host: defaultEchoHost, serverPort: defaultServerPort, clientPort: defaultClientPort)
			}
			
			let first: EventLoopFuture<ChannelResults>? = try await group.next()
			let second: EventLoopFuture<ChannelResults>? = try await group.next()
			
			guard let echoServerResult = try await first?.get().first , let echoClientResult = try await second?.get().first else {
				XCTFail("No result found")

				return
			}

			switch echoServerResult {
				case .success(_):
					break
				case .failure:
					XCTFail("echo server error")
			}

			switch echoClientResult {
				case .success(_):
					break
				case .failure:
					XCTFail("echo client error")
			}
		}
	}

	func testUDPEchoForwarding() async throws {
		try await withThrowingTaskGroup(of: EventLoopFuture<ChannelResults>.self) { group in 
			group.addTask {
				self.setupEchoServer(host: defaultEchoHost, port: defaultServerPort)
			}

			group.addTask {
				self.setupForwarder(host: defaultEchoHost, port: defaultForwardPort, guest: defaultServerPort)
			}

            try await Task.sleep(nanoseconds: 100_000_000)

			group.addTask {
				self.setupEchoClient(host: defaultEchoHost, serverPort: defaultForwardPort, clientPort: defaultClientPort)
			}
			
			let serverTask: EventLoopFuture<ChannelResults>? = try await group.next()
			let _: EventLoopFuture<ChannelResults>? = try await group.next()
			let clientTask: EventLoopFuture<ChannelResults>? = try await group.next()
			
			guard let echoServerResult = try await serverTask?.get().first , let echoClientResult = try await clientTask?.get().first else {
				XCTFail("No result found")

				return
			}

			switch echoServerResult {
				case .success(_):
					break
				case .failure:
					XCTFail("echo server error")
			}

			switch echoClientResult {
				case .success(_):
					break
				case .failure:
					XCTFail("echo client error")
			}

			try await portForwarder?.close().get()
		}
	}
}
