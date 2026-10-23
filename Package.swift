// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "downbender",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "downbender", targets: ["downbender"]),
        .executable(name: "downbender-native-host", targets: ["DownbenderNativeHost"]),
    ],
    targets: [
        .target(name: "DownbenderCore"),
        .executableTarget(name: "downbender", dependencies: ["DownbenderCore"]),
        .executableTarget(name: "DownbenderNativeHost", dependencies: ["DownbenderCore"]),
        .testTarget(
            name: "DownbenderCoreTests",
            dependencies: ["DownbenderCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DownbenderUITests",
            dependencies: ["downbender"]
        ),
    ]
)
