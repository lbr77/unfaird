// swift-tools-version: 5.4

import PackageDescription

let package = Package(
    name: "unfair-swift",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "UnfairKit", targets: ["UnfairKit"]),
        .executable(name: "unfair-swift", targets: ["UnfairCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .exact("0.9.19")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.3.0"..<"2.0.0"),
    ],
    targets: [
        .target(
            name: "UnfairKit",
            dependencies: [
                "UnfairSupport",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(name: "UnfairSupport"),
        .executableTarget(
            name: "UnfairCLI",
            dependencies: [
                "UnfairKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "UnfairKitTests",
            dependencies: [
                "UnfairKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
