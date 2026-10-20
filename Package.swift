// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PingTask",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "PingTask", dependencies: ["CSQLite"], resources: [.process("Resources")])
    ],
    swiftLanguageModes: [.v5]
)
