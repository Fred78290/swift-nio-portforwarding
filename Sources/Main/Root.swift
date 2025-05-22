import Foundation
import ArgumentParser
import Logging
import NIOPortForwarding

let COMMAND_NAME="nio-pfw"

@main
struct Root: ParsableCommand {
	static var configuration = CommandConfiguration(
		commandName: "\(COMMAND_NAME)",
		discussion: "\(COMMAND_NAME) is a tool to proxy tcp/udp port",
		version: CI.version)

	@Argument(help: "Remote host forwarded port")
	public var remoteHost: String = "localhost"

	@Option(name: [.customLong("forward"), .customShort("f")], help: ArgumentHelp("Forwarded port for host", valueName: "host port:guest port/(tcp|udp|both)"))
	public var forwardedPorts: [ForwardedPort] = []

	@Option(name: [.customLong("ttl"), .customShort("t")], help: "TTL for UDP relay connection in seconds")
	public var udpTTL: Int = 5

	@Flag(help: "debug log")
	public var debug: Bool = false

	var mappedPorts: [MappedPort] {
		get {
			self.forwardedPorts.map { forwarded in
				MappedPort(host: forwarded.host, guest: forwarded.guest, proto: forwarded.proto)
			}
		}
	}

	func validate() throws {
		if self.debug {
			portForwarderLogLevel = Logger.Level.debug
		}
	}

	mutating func run() throws {
		let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddresses: ["0.0.0.0", "[::]"], udpConnectionTTL: udpTTL)

		try pfw.bind().wait()
	}
}