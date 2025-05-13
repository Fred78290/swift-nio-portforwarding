import XCTest
import Logging

@testable import NIOPortForwarding
@testable import NIOCore
@testable import NIOPosix

final class CustomPortForwarder: PortForwarder, @unchecked Sendable {
	class CustomTCPPortForwardingServer: TCPPortForwardingServer {
		override func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
			if isDebugLog() {
				Log(self).debug("connection from: \(String(describing: channel.remoteAddress))")
			}

			return ClientBootstrap(group: channel.eventLoop)
				.connect(to: remoteAddress)
				.flatMap { childChannel in
					let (ours, theirs) = GlueHandler.matchedPair()

					if isDebugLog() {
						Log(self).debug("connected to: \(String(describing: childChannel.remoteAddress))")
					}

					return childChannel.pipeline.addHandlers([TCPWrapperHandler(), ours, ErrorHandler()]).flatMap {
						channel.pipeline.addHandlers([theirs, ErrorHandler()])
					}
				}
		}
	}

	override func createTCPPortForwardingServer(on: any EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress) throws -> TCPPortForwardingServer {
		return CustomTCPPortForwardingServer(on: on, bindAddress: bindAddress, remoteAddress: remoteAddress)
	}
}

final class CustomForwarderTest: XCTestCase {
	let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

	override class func setUp() {
		super.setUp()
		portForwarderLogLevel = Logger.Level.debug
	}

	deinit {
		try! group.syncShutdownGracefully()
	}

	func setupForwarder(remoteAddress: SocketAddress, bindAddress: SocketAddress) throws -> PortForwarder {
		return try CustomPortForwarder(group: self.group, remoteAddress: remoteAddress, bindAddress: bindAddress, proto: .tcp)
	}

	func testCustomForwarder() throws {
		let helper = TcpHelper(group: group)
		let remoteAddress = try SocketAddress(unixDomainSocketPath: "/tmp/echo.sock", cleanupExistingSocketFile: true)
		let bindAddress: SocketAddress = try SocketAddress(unixDomainSocketPath: "/tmp/echo.sock.bind", cleanupExistingSocketFile: true)
		let forwarder = try setupForwarder(remoteAddress: remoteAddress, bindAddress: bindAddress)

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
}