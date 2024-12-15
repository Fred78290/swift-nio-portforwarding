import ArgumentParser
import Foundation

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
