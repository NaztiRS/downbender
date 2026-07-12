// swift-tools-version: 6.2
import PackageDescription

// CLT-only: Testing.framework and its interop dylib live under Developer/, not in the
// default module/library search paths. -F, -rpath, and -L flags are needed without Xcode.
let testingFrameworkPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingLibPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "downbender",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "DownbenderCore"),
        .executableTarget(name: "downbender", dependencies: ["DownbenderCore"]),
        .testTarget(
            name: "DownbenderCoreTests",
            dependencies: ["DownbenderCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .unsafeFlags(["-F", testingFrameworkPath]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", testingFrameworkPath,
                    "-L", testingLibPath,
                    "-Xlinker", "-rpath",
                    "-Xlinker", testingFrameworkPath,
                    "-Xlinker", "-rpath",
                    "-Xlinker", testingLibPath,
                ]),
            ]
        ),
    ]
)
