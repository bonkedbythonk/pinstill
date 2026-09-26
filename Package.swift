// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pinstill",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PinstillCore"),
        .executableTarget(name: "Pinstill", dependencies: ["PinstillCore"]),
        .testTarget(
            name: "PinstillCoreTests",
            dependencies: ["PinstillCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
