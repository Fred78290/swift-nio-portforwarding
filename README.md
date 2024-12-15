[![swift-nio-portforwarding](https://github.com/Fred78290/swift-nio-portforwarding/actions/workflows/ci.yml/badge.svg)](https://github.com/Fred78290/swift-nio-portforwarding/actions/workflows/ci.yml)

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
    MappedPort(host: 1053, guest: 53, proto: .tcp)
]
let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "0.0.0.0", udpConnectionTTL: 5)

let _ = try pfw.bind().wait()

```

Simpler DNS port forwarding

```swift
let remoteHost = "8.8.8.8"
let mappedPorts = [
    MappedPort(host: 1053, guest: 53, proto: .both),
]
let pfw = try PortForwarder(remoteHost: remoteHost, mappedPorts: mappedPorts, bindAddress: "0.0.0.0", udpConnectionTTL: 5)

let _ = try pfw.bind().wait()

```
