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
				Log(self).debug("Close UDP tunnel \(self.inboundChannel) <--> \(self.remoteAddress)")
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
			Log(self).debug("received data from: \(data.remoteAddress), forward to: \(self.remoteAddress)")
		}

		self.last = .now

		outboundChannel.writeAndFlush(self.wrapOutboundOut(envelope), promise: nil)
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Log(self).error("Error in tunnel: \(self.outboundChannel) <--> \(self.remoteAddress), \(error)")

		context.close(promise: nil)
	}
}

public class InboundUDPWrapperHandler: ChannelInboundHandler {
	public typealias InboundIn = AddressedEnvelope<ByteBuffer>
	public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

	let remoteAddress: SocketAddress
	let bindAddress: SocketAddress
	let ttl: Int
	var task: RepeatedTask?

	public init(remoteAddress: SocketAddress, bindAddress: SocketAddress, ttl: Int) {
		self.remoteAddress = remoteAddress
		self.bindAddress = bindAddress
		self.ttl = ttl
	}

	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let envelope = self.unwrapInboundIn(data)
		let eventLoop = context.eventLoop
		let outboundChannel = context.channel

		if isDebugLog() {
			Log(self).debug("received data from: \(envelope.remoteAddress)")
		}

		let client: DatagramBootstrap = DatagramBootstrap(group: eventLoop)
			.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { inboundChannel in
				var promise: EventLoopPromise<Void>? = nil
				let data: AddressedEnvelope<ByteBuffer> = AddressedEnvelope<ByteBuffer>(remoteAddress: self.remoteAddress, data: envelope.data)
				let channelFuture = inboundChannel.pipeline.addHandler(UDPWrapperHandler(remoteAddress:envelope.remoteAddress,
				                                                                         inboundChannel: inboundChannel,
				                                                                         outboundChannel: outboundChannel,
				                                                                         ttl: self.ttl))

				if isDebugLog() {
					Log(self).debug("forward data from: \(envelope.remoteAddress) to \(self.remoteAddress)")

					promise = eventLoop.makePromise(of: Void.self)
					promise!.futureResult.whenComplete { result in
						switch result {
						case .success:
							Log(self).debug("Success forward data from: \(envelope.remoteAddress) to \(self.remoteAddress)")
						case let .failure(error):
							Log(self).error("Failed to forward data to \(self.remoteAddress), \(error)")
						}
					}
				}

				inboundChannel.writeAndFlush(UDPWrapperHandler.wrapOutboundOut(data), promise: promise)

				return channelFuture
			}

		let server: EventLoopFuture<any Channel>

		switch self.bindAddress {
		case .unixDomainSocket:
			server = client.bind(unixDomainSocketPath: "/tmp/portforward-\(UUID().uuidString).sock", cleanupExistingSocketFile: true)
		case .v4(let address):
			server = client.bind(host: address.host, port: 0)
		case .v6(let address):
			server = client.bind(host: address.host, port: 0)
		}

		server.whenComplete { result in
			switch result {
			case .success:
				Log(self).debug("Bind success to receive data to \(self.remoteAddress)")
			case let .failure(error):
				Log(self).error("Failed to bind to \(self.remoteAddress), \(error)")
			}
		}
	}

	public func channelReadComplete(context: ChannelHandlerContext) {
		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.flush()
	}

	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		Log(self).error("Caught error: \(error.localizedDescription)")

		// As we are not really interested getting notified on success or failure we just pass nil as promise to
		// reduce allocations.
		context.close(promise: nil)
	}

}

open class UDPPortForwardingServer: PortForwarding {
	public let bootstrap: Bindable
	public let eventLoop: EventLoop
	public let bindAddress: SocketAddress
	public let remoteAddress: SocketAddress
	public var channel: Channel?
	public var proto: MappedPort.Proto { return .udp }
	public var ttl: Int = 60

	public init(on: EventLoop,
	            bindAddress: SocketAddress,
	            remoteAddress: SocketAddress,
	            ttl: Int) {

		let bootstrap = DatagramBootstrap(group: on)

		self.eventLoop = on
		self.bindAddress = bindAddress
		self.remoteAddress = remoteAddress
		self.ttl = ttl
		self.bootstrap = bootstrap

		_ = bootstrap.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.channelInitializer { inboundChannel in
				return self.channelInitializer(channel: inboundChannel)
			}
	}

    open func channelInitializer(channel: Channel) -> EventLoopFuture<Void> {
		channel.pipeline.addHandler(InboundUDPWrapperHandler(remoteAddress: remoteAddress, bindAddress: bindAddress, ttl: ttl))
    }

	public func setChannel(_ channel: Channel?) {
		self.channel = channel
	}
}
