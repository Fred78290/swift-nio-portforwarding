public struct MappedPort: Codable {
	public enum Proto: String, Codable {
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

