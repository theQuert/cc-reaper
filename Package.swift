// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CCReaper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CCReaper", targets: ["CCReaperApp"]),
        .library(name: "CCReaperCore", targets: ["CCReaperCore"])
    ],
    targets: [
        .target(
            name: "CCReaperCore",
            path: "Sources/CCReaperCore"
        ),
        .executableTarget(
            name: "CCReaperApp",
            dependencies: ["CCReaperCore"],
            path: "Sources/CCReaperApp"
        ),
        .testTarget(
            name: "CCReaperCoreTests",
            dependencies: ["CCReaperCore"],
            path: "tests/CCReaperCoreTests"
        )
    ]
)
