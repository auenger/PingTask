// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PingTask",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "PingTask", resources: [.process("Resources")])],
    swiftLanguageModes: [.v5]
)
