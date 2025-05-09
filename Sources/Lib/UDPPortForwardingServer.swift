import Foundation
import Dispatch
import Logging
import NIOCore
import NIOPosix

extension DatagramBootstrap: Bindable {

}

public class UDPWrapperHandler: ChannelInboundHandler {
	public typealias InboundIn = AddressedEnvelope<ByteBuffer>
	public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

	let inboundChannel: Channel
	let outboundChannel: Channel
	let remoteAddress: SocketAddress
	let ttl: Int

	var last: Date
	var task: RepeatedTask?

	internal static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.UDPWrapperHandler")
		logger.logLevel = portForwarderLogLevel

		return logger
	}

	deinit {
		if let task = self.task {
			task.cancel(promise: nil)
		}
	}

	public init(remoteAddress: SocketAddress, inboundChannel: Channel, outboundChannel: Channel, ttl: Int) {
		self.last = .now
		self.inboundChannel = inboundChannel
		self.outboundChannel = outboundChannel
		self.task = nil
		self.remoteAddress = remoteAddress
		self.ttl = ttl
		self.task = inboundChannel.eventLoop.scheduleRepeatedAsyncTask(initialDelay: TimeAmount.seconds(Int64(ttl)),
		                                                               delay: TimeAmount.seconds(1),
		                                                               maximumAllowableJitter: TimeAmount.seconds(1),
		                                                               notifying: nil, self.scheduled)
	}

	@Sendable private func scheduled(_ task: RepeatedTask) -> EventLoopFuture<Void> {
		let dt: TimeInterval = Date.now.timeIntervalSince(self.last)

		if dt > TimeInterval(self.ttl) {
			if isDebugLog() {
				Self.Log().debug("Close UDP tunnel \(self.inboundChannel) <--> \(self.remoteAddress)")
			}

			inboundChannel.close(promise: nil)

			task.cancel()
		}

		return self.inboundChannel.eventLoop.makeSucceededFuture(())
	}

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let data = self.unwrapInboundIn(data)
		let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: self.remoteAddress, data: data.data)

		if isDebugLog() {
			Self.Log().debug("received data from: \(data.remoteAddress), forward to: \(self.remoteAddress)")
		}

		self.last = .now

		outboundChannel.writeAndFlush(self.wrapOutboundOut(envelope), promise: nil)
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Self.Log().error("Error in tunnel: \(self.outboundChannel) <--> \(self.remoteAddress), \(error)")

		context.close(promise: nil)
	}
}

public class InboundUDPWrapperHandler: ChannelInboundHandler {
	public typealias InboundIn = AddressedEnvelope<ByteBuffer>
	public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

	let remoteAddress: SocketAddress
	let ttl: Int
	var task: RepeatedTask?

	internal static func Log() -> Logger {
		var logger = Logger(label: "com.aldunelabs.portforwarder.InboundUDPWrapperHandler")
		logger.logLevel = portForwarderLogLevel

		return logger
	}

	public init(remoteAddress: SocketAddress, ttl: Int) {
		self.remoteAddress = remoteAddress
		self.ttl = ttl
	}

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let envelope = self.unwrapInboundIn(data)
		let eventLoop = context.eventLoop
		let outboundChannel = context.channel

		if isDebugLog() {
			Self.Log().debug("received data from: \(envelope.remoteAddress)")
		}

		let client: DatagramBootstrap = DatagramBootstrap(group: eventLoop)
			.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { inboundChannel in
				let data: AddressedEnvelope<ByteBuffer> = AddressedEnvelope<ByteBuffer>(remoteAddress: self.remoteAddress, data: envelope.data)
				let channelFuture = inboundChannel.pipeline.addHandler(UDPWrapperHandler(remoteAddress:envelope.remoteAddress,
				                                                                         inboundChannel: inboundChannel,
				                                                                         outboundChannel: outboundChannel,
				                                                                         ttl: self.ttl))

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

public class UDPPortForwardingServer: PortForwarding {
	public let bootstrap: Bindable
	public let eventLoop: EventLoop
	public let bindAddress: SocketAddress
	public let remoteAddress: SocketAddress
	public var channel: Channel?

	public init(on: EventLoop,
	            bindAddress: SocketAddress,
	            remoteAddress: SocketAddress,
	            ttl: Int) {

		self.eventLoop = on
		self.bindAddress = bindAddress
		self.remoteAddress = remoteAddress
		self.bootstrap = DatagramBootstrap(group: on)
			.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { inboundChannel in
				inboundChannel.pipeline.addHandler(InboundUDPWrapperHandler(remoteAddress: remoteAddress, ttl: ttl))
			}
	}

	public func setChannel(_ channel: any NIOCore.Channel) {
		self.channel = channel
	}
}
