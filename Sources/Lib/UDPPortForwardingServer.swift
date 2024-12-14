import Foundation
import Dispatch
import Logging
import NIOCore
import NIOPosix

extension DatagramBootstrap: Bindable {

}

final class UDPWrapperHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

	let logger: Logger
	var last: Date
	let channel: Channel
	var task: RepeatedTask?

	private static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.UDPWrapperHandler")
		logger.logLevel = portForwarderLogLevel

		return logger
	}

	deinit {
		if let task = self.task {
			task.cancel(promise: nil)
		}
	}

	init(remoteAddress: SocketAddress, channel: Channel) {
		self.last = .now
		self.channel = channel
		self.logger = Logger(label: "com.aldunelabs.portforwarder.UDPWrapperHandler")
		self.task = nil
		self.remoteAddress = remoteAddress

		self.task = channel.eventLoop.scheduleRepeatedAsyncTask(initialDelay: TimeAmount.seconds(60),
				delay: TimeAmount.seconds(1),
				maximumAllowableJitter: TimeAmount.seconds(1),
				notifying: nil, self.scheduled)
	}

	@Sendable private func scheduled(_ task: RepeatedTask) -> EventLoopFuture<Void> {
		let dt: TimeInterval = Date.now.timeIntervalSince(self.last)

			if isDebugLog() {
				Self.Log().debug("Close UDP tunnel \(self.inboundChannel) <--> \(self.remoteAddress)")
			}

			channel.close(promise: nil)

			task.cancel()
		}

		return self.channel.eventLoop.makeSucceededFuture(())
	}

	func channelActive(context: ChannelHandlerContext) {
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let data = self.unwrapInboundIn(data)
		let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: self.remoteAddress, data: data.data)

		if isDebugLog() {
			Self.Log().debug("received data from: \(data.remoteAddress), forward to: \(self.remoteAddress)")
		}

		self.last = .now

		context.writeAndFlush(self.wrapOutboundOut(envelope), promise: nil)
	}

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Self.Log().error("Error in tunnel: \(self.outboundChannel) <--> \(self.remoteAddress), \(error)")

		context.close(promise: nil)
    }
}

final class InboundUDPWrapperHandler: ChannelInboundHandler {
	public typealias InboundIn = AddressedEnvelope<ByteBuffer>
	public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

	let remoteAddress: SocketAddress
	let logger: Logger
	var task: RepeatedTask?

	private static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.InboundUDPWrapperHandler")
		logger.logLevel = portForwarderLogLevel

		return logger
	}

	init(remoteAddress: SocketAddress, ttl: Int) {
		self.remoteAddress = remoteAddress
		self.logger = Logger(label: "com.aldunelabs.portforwarder.InboundUDPWrapperHandler")
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let envelope = self.unwrapInboundIn(data)
		let eventLoop = context.eventLoop

		if isDebugLog() {
			Self.Log().debug("received data from: \(envelope.remoteAddress)")
		}

		let client: DatagramBootstrap = DatagramBootstrap(group: eventLoop)
			.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { inboundChannel in
				let data: AddressedEnvelope<ByteBuffer> = AddressedEnvelope<ByteBuffer>(remoteAddress: self.remoteAddress, data: envelope.data)
				let channelFuture = inboundChannel.pipeline.addHandler(UDPWrapperHandler(remoteAddress:envelope.remoteAddress, channel: inboundChannel))

				if isDebugLog() {
					Self.Log().debug("forward data from: \(envelope.remoteAddress) to \(self.remoteAddress)")
				}

				inboundChannel.writeAndFlush(UDPWrapperHandler.wrapOutboundOut(data), promise: nil)

				return channelFuture
		}

		let server = client.bind(host: "0.0.0.0", port: 0)
		
		server.whenComplete { result in
			switch result {
			case .success:
				Self.Log().info("Success to send data to \(self.remoteAddress)")
			case let .failure(error):
				Self.Log().error("Failed to send to \(self.remoteAddress), \(error)")
			}
		}
	}

	public func channelReadComplete(context: ChannelHandlerContext) {
		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.flush()
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Self.Log().error("Caught error: \(error.localizedDescription)")

		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.close(promise: nil)
	}

}

final class UDPPortForwardingServer: PortForwarding {
	let bootstrap: Bindable
	let serverLoop: EventLoop
	let group: EventLoopGroup
	let bindAddress: SocketAddress
	let remoteAddress: SocketAddress
	var channel: Channel?

	init(group: EventLoopGroup,
		bindAddress: SocketAddress,
		remoteAddress: SocketAddress) {

		self.group = group
		self.serverLoop = group.next()
		self.bindAddress = bindAddress
		self.remoteAddress = remoteAddress
		self.bootstrap = DatagramBootstrap(group: self.serverLoop)
			.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { inboundChannel in
				inboundChannel.pipeline.addHandler(InboundUDPWrapperHandler(remoteAddress: remoteAddress))
		}
	}
	
	func setChannel(_ channel: any NIOCore.Channel) {
		self.channel = channel
	}
}
