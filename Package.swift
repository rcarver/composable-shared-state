// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "composable-scoped-state",
    platforms: [
        .iOS(.v13),
//        .macOS(.v10_15),
//        .tvOS(.v13),
//        .watchOS(.v6),
    ],
    products: [
        .library(
            name: "ComposableScopedState",
            targets: [
                "ComposableScopedState"
            ]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture",
            branch: "prerelease/1.0"
        )
    ],
    targets: [
        .target(
            name: "ComposableScopedState",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ComposableScopedStateTests",
            dependencies: ["ComposableScopedState"]),
    ]
)
