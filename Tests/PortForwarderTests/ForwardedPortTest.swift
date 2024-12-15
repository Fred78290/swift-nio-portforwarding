import XCTest

@testable import NIOPortForwarding

final class ForwardedPortTests: XCTestCase {

	func testHostPortOnly() throws {
		let forwardedPort = ForwardedPort(argument: "80")

		XCTAssertEqual(forwardedPort.description, "80:80/tcp")
	}

	func testHostAndGuestPortOnly() throws {
		let forwardedPort = ForwardedPort(argument: "80:8080")

		XCTAssertEqual(forwardedPort.description, "80:8080/tcp")
	}

	func testHostAndGuestPortWithProtocol() throws {
		let forwardedPort = ForwardedPort(argument: "80:8080/both")

		XCTAssertEqual(forwardedPort.description, "80:8080/both")
	}
}