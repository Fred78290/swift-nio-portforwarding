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
		.package(url: "https://github.com/Fred78290/swift-argument-parser", revision: "d554955e8c280aa4c4a05a039a968f0205656e77"),
		.package(url: "https://github.com/apple/swift-nio.git", "2.60.0" ..< "3.0.0"),
		.package(url: "https://github.com/apple/swift-log.git", "1.5.0" ..< "2.0.0"),
		.package(url: "https://github.com/apple/swift-atomics.git", .upToNextMajor(from: "1.3.0")),
	],
	targets: [
		.target(
			name: "NIOPortForwarding",
			dependencies: [
				.product(name: "NIOCore", package: "swift-nio"),
				.product(name: "NIOPosix", package: "swift-nio"),
				.product(name: "NIOHTTP1", package: "swift-nio"),
				.product(name: "Logging", package: "swift-log"),
				.product(name: "Atomics", package: "swift-atomics"),
			],
			path: "Sources/Lib"
		),
		.executableTarget(
			name: "PortForwarder",
			dependencies: [
				.target(name: "NIOPortForwarding"),
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				.product(name: "NIOCore", package: "swift-nio"),
				.product(name: "NIOPosix", package: "swift-nio"),
				.product(name: "NIOHTTP1", package: "swift-nio"),
				.product(name: "Logging", package: "swift-log"),
			],
			path: "Sources/Main"
		),
		.testTarget(
			name: "PortForwarderTests",
			dependencies: [
				"NIOPortForwarding",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			]
		)
	]
)
