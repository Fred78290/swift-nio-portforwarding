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

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let data = self.unwrapInboundIn(data)

		if isDebugLog() {
			Log(self).debug("read data from: \(String(describing: context.channel.remoteAddress))")
		}

		context.fireChannelRead(self.wrapInboundOut(data))
	}

	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		let data = self.unwrapOutboundIn(data)

		if isDebugLog() {
			Log(self).debug("write data to: \(String(describing: context.channel.remoteAddress))")
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
	public var proto: MappedPort.Proto { return .tcp }

	public init(on: EventLoop, bindAddress: SocketAddress, remoteAddress: SocketAddress) {
		let bootstrap = ServerBootstrap(group: on)

		self.eventLoop = on
		self.bindAddress = bindAddress
		self.remoteAddress = remoteAddress
		self.bootstrap = bootstrap

		_ = bootstrap.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelInitializer { inboundChannel in
				return self.childChannelInitializer(channel: inboundChannel)
			}
	}

	internal func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
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

	public func setChannel(_ channel: any NIOCore.Channel) {
		self.channel = channel
	}
}

