// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "CCReaperCore", targets: ["CCReaperCore"])
]

var targets: [Target] = [
    .target(
        name: "CCReaperSpawn",
        path: "Sources/CCReaperSpawn",
        publicHeadersPath: "include"
    ),
    .target(
        name: "CCReaperCore",
        dependencies: ["CCReaperSpawn"],
        path: "Sources/CCReaperCore"
    ),
    .testTarget(
        name: "CCReaperCoreTests",
        dependencies: ["CCReaperCore"],
        path: "tests/CCReaperCoreTests"
    )
]

#if os(macOS)
products.insert(.executable(name: "CCReaper", targets: ["CCReaperApp"]), at: 0)
targets.insert(
    .executableTarget(
        name: "CCReaperApp",
        dependencies: ["CCReaperCore"],
        path: "Sources/CCReaperApp"
    ),
    at: 1
)
#endif

let package = Package(
    name: "CCReaper",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
