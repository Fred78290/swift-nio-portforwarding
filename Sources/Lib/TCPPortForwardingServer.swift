import Dispatch
import Logging
import NIOCore
import NIOPosix

extension ServerBootstrap: Bindable {

}

final class TCPWrapperHandler: ChannelDuplexHandler {
	typealias InboundIn = ByteBuffer
	typealias InboundOut = ByteBuffer
	typealias OutboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	private static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.TCPWrapperHandler")
		logger.logLevel = portForwarderLogLevel

		return logger
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let data = self.unwrapInboundIn(data)

		if isDebugLog() {
			Self.Log().debug("read data from: \(String(describing: context.channel.remoteAddress))")
		}

		context.fireChannelRead(self.wrapInboundOut(data))
	}

	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		let data = self.unwrapOutboundIn(data)

		if isDebugLog() {
			Self.Log().debug("write data to: \(String(describing: context.channel.remoteAddress))")
		}

		context.write(self.wrapOutboundOut(data), promise: promise)
	}
}

public class TCPPortForwardingServer: PortForwarding {
	public let bootstrap: Bindable
	public let eventLoop: EventLoop
	public let bindAddress: SocketAddress
	public let remoteAddress: SocketAddress
	public var channel: Channel?

	internal static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.TCPPortForwardingServer")
		logger.logLevel = portForwarderLogLevel

		return logger
	}

	public init(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress) {

		self.eventLoop = on
		self.bindAddress = bindAddress
		self.remoteAddress = remoteAddress
		self.bootstrap = ServerBootstrap(group: on)
			.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelInitializer { inboundChannel in
				if isDebugLog() {
					Self.Log().debug("connection from: \(String(describing: inboundChannel.remoteAddress))")
				}

				return ClientBootstrap(group: inboundChannel.eventLoop)
					.connect(to: remoteAddress)
					.flatMap { childChannel in
						let (ours, theirs) = GlueHandler.matchedPair()

						if isDebugLog() {
							Self.Log().debug("connected to: \(String(describing: childChannel.remoteAddress))")
						}

						return childChannel.pipeline.addHandlers([TCPWrapperHandler(), ours, ErrorHandler()]).flatMap {
							inboundChannel.pipeline.addHandlers([theirs, ErrorHandler()])
						}
					}
			}
	}

	public func setChannel(_ channel: any NIOCore.Channel) {
		self.channel = channel
	}
}

