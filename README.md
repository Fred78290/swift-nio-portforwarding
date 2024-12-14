[![sswg:graduated|104x20](https://img.shields.io/badge/sswg-graduated-green.svg)](https://github.com/swift-server/sswg/blob/main/process/incubation.md#graduated-level)

# SwiftNIO Port Forwarding

SwiftNIO Port Forwarding is a package to create UDP/TCP port forwarding aka docker with SwiftNIO

## Package organisation

This package contains a library and an executable as a simple demo.

## Simple usage

HTTP/HTTPS port forwarding

```swift
let remoteHost = "google.com"
let mappedPorts = [
    MappedPort(host: 1080, guest: 80, proto: .tcp),
    MappedPort(host: 1043, guest: 443, proto: .tcp)
]
let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "0.0.0.0")

let _ = try pfw.bind()?.wait()

```

DNS port forwarding

```swift
let remoteHost = "8.8.8.8"
let mappedPorts = [
    MappedPort(host: 1053, guest: 53, proto: .udp),
    MappedPort(host: 1053, guest: 443, proto: .tcp)
]
let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "0.0.0.0")

let _ = try pfw.bind()?.wait()

```

Simpler DNS port forwarding

```swift
let remoteHost = "8.8.8.8"
let mappedPorts = [
    MappedPort(host: 1053, guest: 53, proto: .both),
]
let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "0.0.0.0")

let _ = try pfw.bind()?.wait()

```
