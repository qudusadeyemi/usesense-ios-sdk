// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "UseSenseSDK",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "UseSenseSDK",
            targets: ["UseSenseSDK"]
        ),
    ],
    targets: [
        .target(
            name: "UseSenseSDK",
            dependencies: [],
            path: "Sources/UseSense",
            exclude: [],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "UseSenseSDKTests",
            dependencies: ["UseSenseSDK"],
            path: "Tests/UseSenseTests"
        ),
    ]
)
