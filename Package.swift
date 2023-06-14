// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "composable-shared-state",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
//        .tvOS(.v13),
//        .watchOS(.v6),
    ],
    products: [
        .library(name: "ComposableSharedState", targets: ["ComposableSharedState"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "0.54.0")
    ],
    targets: [
        .target(
            name: "ComposableSharedState",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ComposableSharedStateTests",
            dependencies: ["ComposableSharedState"]),
    ]
)
