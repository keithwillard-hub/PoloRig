// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IC705SessionManager",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "IC705SessionManager",
            targets: ["SessionManager"]
        ),
        .executable(
            name: "ic705-cli",
            targets: ["CLI"]
        ),
        .executable(
            name: "ic705-session-cli",
            targets: ["SequenceCLI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],
    targets: [
        // Transport layer (UDP + CI-V protocol)
        .target(
            name: "Transport",
            dependencies: [],
            path: "Sources/Transport"
        ),

        // Session management (state machine + operation queue)
        .target(
            name: "SessionManager",
            dependencies: ["Transport"],
            path: "Sources/SessionManager"
        ),

        // CLI executable
        .executableTarget(
            name: "CLI",
            dependencies: [
                "SessionManager",
                "Transport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),

        .executableTarget(
            name: "SequenceCLI",
            dependencies: [
                "SessionManager",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SequenceCLI"
        ),

        // Tests
        .testTarget(
            name: "TransportTests",
            dependencies: ["Transport"],
            path: "Tests/TransportTests"
        ),

        .testTarget(
            name: "SessionManagerTests",
            dependencies: ["SessionManager", "Transport"],
            path: "Tests/SessionManagerTests"
        ),
    ]
)
