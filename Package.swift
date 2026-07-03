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
            path: "Sources/SmritiCLI"
        ),
        .testTarget(
            name: "SmritiKitTests",
            dependencies: ["SmritiKit"],
            path: "Tests/SmritiKitTests"
        ),
    ]
)
