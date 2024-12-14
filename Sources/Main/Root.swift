import Foundation
import ArgumentParser
import Logging
import NIOPortForwarding

let COMMAND_NAME="nio-pfw"

public struct ForwardedPort: Codable {
	public var proto: MappedPort.Proto = .tcp
	public var host: Int = -1
	public var guest: Int = -1

	public init() {
		
	}
}

extension ForwardedPort: CustomStringConvertible, ExpressibleByArgument {
	public var description: String {
		"\(host):\(guest)/\(proto)"
	}

	public init(argument: String) {
		self.init()

		let expr = try! NSRegularExpression(pattern: #"(?<host>\d+)(:(?<guest>\d+)(\/(?<proto>tcp|udp|both))?)?"#, options: [])
		let range = NSRange(argument.startIndex..<argument.endIndex, in: argument)

		guard let match = expr.firstMatch(in: argument, options: [], range: range) else {
			return
		}

		if let hostRange = Range(match.range(withName: "host"), in: argument) {
			self.host = Int(argument[hostRange]) ?? 0
		}

		if let guestRange = Range(match.range(withName: "guest"), in: argument) {
			self.guest = Int(argument[guestRange]) ?? 0
		} else {
			self.guest = self.host
		}

		self.proto = .tcp

		if let protoRange = Range(match.range(withName: "proto"), in: argument) {
			if let proto = MappedPort.Proto(rawValue: String(argument[protoRange])) {
				self.proto = proto
			}
		}
	}
}

@main
struct Root: ParsableCommand {
	static var configuration = CommandConfiguration(
		commandName: "\(COMMAND_NAME)",
		discussion: "\(COMMAND_NAME) is a tool to proxy tcp/udp port",
		version: CI.version)

	@Argument(help: "Remote host forwarded port")
	public var remoteHost: String = "localhost"

	@Option(name: [.customLong("forward"), .customShort("f")], help: ArgumentHelp("forwarded port for host", valueName: "host:guest/(tcp|udp|both)"))
	public var forwardedPorts: [ForwardedPort] = []

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
		let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "0.0.0.0")

		try pfw.bind().wait()
	}
}