// swift-tools-version:5.8.1
import PackageDescription

let package = Package(
	name: "nio-port-forwarder",
	platforms: [
		.macOS(.v13),
		.iOS(.v14),
		.tvOS(.v14)
	],
	products: [
		.library(name: "NIOPortForwarding", targets: ["NIOPortForwarding"]),
		.executable(name: "nio-pfw", targets: ["PortForwarder"]),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.5.0")),
		.package(url: "https://github.com/apple/swift-nio.git", "2.60.0" ..< "3.0.0"),
		.package(url: "https://github.com/apple/swift-log.git", "1.5.0" ..< "2.0.0"),
	],
	targets: [
		.target(
			name: "NIOPortForwarding",
			dependencies: [
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				.product(name: "NIOCore", package: "swift-nio"),
				.product(name: "NIOPosix", package: "swift-nio"),
				.product(name: "NIOHTTP1", package: "swift-nio"),
				.product(name: "Logging", package: "swift-log"),
			],
			path: "Sources/Lib"
		),
		.executableTarget(
			name: "PortForwarder",
			dependencies: [
				.target(name: "NIOPortForwarding"),
				.product(name: "NIOCore", package: "swift-nio"),
				.product(name: "NIOPosix", package: "swift-nio"),
				.product(name: "NIOHTTP1", package: "swift-nio"),
				.product(name: "Logging", package: "swift-log"),
			],
			path: "Sources/Main"
		),
		.testTarget(name: "PortForwarderTests", dependencies: ["NIOPortForwarding"])
	]
)
