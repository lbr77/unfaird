// swift-tools-version: 5.4

import PackageDescription

let package = Package(
    name: "unfaird",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
    ],
    products: [
        .executable(name: "UnfairDaemon", targets: ["UnfairDaemon"]),
    ],
    dependencies: [
        .package(name: "unfair-swift", url: "https://github.com/lbr77/unfair.git", .revision("d725733e8975f160d2045a4271d03a0f378fa155")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMinor(from: "1.0.0")),
        .package(url: "https://github.com/vapor/vapor.git", .exact("4.60.0")),
    ],
    targets: [
        .target(name: "UnfairDaemonSupport"),
        .executableTarget(
            name: "UnfairDaemon",
            dependencies: [
                "UnfairDaemonSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "UnfairKit", package: "unfair-swift"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)
