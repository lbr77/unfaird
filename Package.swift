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
        // Vendored under Vendor/unfair. Re-sync with scripts/vendor-unfair.sh.
        .package(path: "Vendor/unfair"),
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
