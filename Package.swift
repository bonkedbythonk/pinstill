// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pinwall",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PinwallCore"),
        .executableTarget(name: "Pinwall", dependencies: ["PinwallCore"]),
        .testTarget(
            name: "PinwallCoreTests",
            dependencies: ["PinwallCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
