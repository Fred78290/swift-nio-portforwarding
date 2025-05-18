public struct MappedPort: Sendable, Codable {
	public enum Proto: String, Sendable, Codable {
		case tcp
		case udp
		case both
		case none
	}

	public let proto: Proto
	public let host: Int
	public let guest: Int

	public init(host: Int, guest: Int, proto: Proto = .tcp) {
		self.host = host
		self.guest = guest
		self.proto = proto
	}
}

extension MappedPort: Equatable {
	public static func == (lhs: MappedPort, rhs: MappedPort) -> Bool {
		return lhs.host == rhs.host && lhs.guest == rhs.guest && lhs.proto == rhs.proto
	}
}