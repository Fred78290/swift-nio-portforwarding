// swift-tools-version:5.7
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
	name: "nio-port-forwarder",
	products: [
		.library(name: "NIOPortForwarding", targets: ["NIOPortForwarding"]),
		.executable(name: "nio-pfw", targets: ["PortForwarder"]),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
		.package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.6.2"),
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
