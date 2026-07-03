// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Smriti",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "smriti", targets: ["smriti"]),
        .library(name: "SmritiKit", targets: ["SmritiKit"]),
    ],
    targets: [
        .target(
            name: "SmritiKit",
            path: "Sources/SmritiKit",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "smriti",
            dependencies: ["SmritiKit"],
            path: "Sources/SmritiCLI",
            linkerSettings: [
                // Embed Info.plist so TCC (microphone, speech recognition)
                // has usage descriptions for this unbundled binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Supporting/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "SmritiKitTests",
            dependencies: ["SmritiKit"],
            path: "Tests/SmritiKitTests"
        ),
    ]
)
