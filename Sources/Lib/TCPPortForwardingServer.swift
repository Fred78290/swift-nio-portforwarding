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

		context.fireChannelRead(self.wrapInboundOut(data))
	}

	func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
		let data = self.unwrapOutboundIn(data)

		context.write(self.wrapOutboundOut(data), promise: promise)
	}
}

final class TCPPortForwardingServer: PortForwarding {
	let bootstrap: Bindable
    let serverLoop: EventLoop
	let group: EventLoopGroup
	let bindAddress: SocketAddress
	let remoteAddress: SocketAddress
	var channel: Channel?

	init(group: EventLoopGroup, bindAddress: SocketAddress, remoteAddress: SocketAddress) {

		self.group = group
		self.serverLoop = group.next()
		self.bindAddress = bindAddress
		self.remoteAddress = remoteAddress
		self.bootstrap = ServerBootstrap(group: self.serverLoop)
			.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelInitializer { inboundChannel in
				return ClientBootstrap(group: inboundChannel.eventLoop)
					.connect(to: remoteAddress)
					.flatMap { childChannel in
						let (ours, theirs) = GlueHandler.matchedPair()

						return childChannel.pipeline.addHandlers([TCPWrapperHandler(), ours, ErrorHandler()]).flatMap {
							inboundChannel.pipeline.addHandlers([theirs, ErrorHandler()])
						}
					}
			}
	}

	func setChannel(_ channel: any NIOCore.Channel) {
		self.channel = channel
	}
}

