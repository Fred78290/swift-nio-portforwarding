import XCTest
import Logging

@testable import NIOPortForwarding
@testable import NIOCore
@testable import NIOPosix

final class CustomPortForwarder: PortForwarder, @unchecked Sendable {
	class CustomTCPPortForwardingServer: TCPPortForwardingServer {
		var runningTask: Task<Void, any Error>? = nil

		func stream(fromChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, toChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
			try await fromChannel.executeThenClose { (fromInput: NIOAsyncChannelInboundStream<ByteBuffer>, fromOutput: NIOAsyncChannelOutboundWriter<ByteBuffer>) in
				try await toChannel.executeThenClose { (toInput: NIOAsyncChannelInboundStream<ByteBuffer>, toOutput: NIOAsyncChannelOutboundWriter<ByteBuffer>) in
					await withTaskGroup(of: Void.self) { group in

						group.addTask {
							do {
								for try await data in fromInput {
									try await toOutput.write(data)
								}
							} catch {
								Log(self).error("Failed to read from input: \(error)")
							}
						}

						group.addTask {
							do {
								for try await data in toInput {
									try await fromOutput.write(data)
								}
							} catch {
								Log(self).error("Failed to read from output: \(error)")
							}
						}

						await group.waitForAll()
					}
				}
			}
		}

		override func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
			if isDebugLog() {
				Log(self).debug("connection from: \(String(describing: channel.remoteAddress))")
			}

			ClientBootstrap(group: channel.eventLoop)
				.connect(to: remoteAddress)
				.flatMapThrowing { childChannel in
					return (
						try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: childChannel),
						try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
					)
				}.whenComplete {
					switch $0 {
					case .success(let channels):
						self.runningTask = Task {			
							defer {
								self.runningTask = nil
							}

							do {
								try await self.stream(fromChannel: channels.0, toChannel: channels.1)
							} catch {
								Log(self).error("Failed to stream data: \(error)")
								throw error
							}
						}
					case .failure(let error):
						Log(self).error("Failed to connect to remote address: \(error)")
					}
				}

			return channel.eventLoop.makeSucceededVoidFuture()
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