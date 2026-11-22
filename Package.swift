// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AGYSwitcher",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AGYCore", resources: [.process("Resources")]),
        .testTarget(name: "AGYCoreTests", dependencies: ["AGYCore"]),
    ]
)
