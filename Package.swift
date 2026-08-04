// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "unfaird",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v15),
    ],
    products: [
        .executable(name: "UnfairDaemon", targets: ["UnfairDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lbr77/unfair.git", revision: "503484cc7f0c96a0aad4310b40abcd93f91d5e2a"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.60.0"),
    ],
    targets: [
        .target(name: "UnfairDaemonSupport"),
        .executableTarget(
            name: "UnfairDaemon",
            dependencies: [
                "UnfairDaemonSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "UnfairKit", package: "unfair"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)
