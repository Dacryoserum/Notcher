// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notcher",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Notcher", targets: ["Notcher"])],
    targets: [
        .target(name: "NotcherCore"),
        .executableTarget(
            name: "Notcher",
            dependencies: ["NotcherCore"],
            resources: [.copy("Resources/MediaBridge.js")],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("IOKit")]
        ),
        .testTarget(name: "NotcherCoreTests", dependencies: ["NotcherCore"]),
        .testTarget(name: "NotcherIntegrationTests", dependencies: ["Notcher"])
    ]
)
