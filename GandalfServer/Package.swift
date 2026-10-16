// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GandalfServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GandalfCore", targets: ["GandalfCore"]),
        .executable(name: "gandalf", targets: ["gandalf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "GandalfCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "gandalf",
            dependencies: [
                "GandalfCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GandalfCoreTests",
            dependencies: ["GandalfCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
