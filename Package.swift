// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "unfaird",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "UnfairDaemon", targets: ["UnfairDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lbr77/unfair.git", revision: "ba53840e3785557e5e5ee4c4d7b616e05fa031c1"),
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
