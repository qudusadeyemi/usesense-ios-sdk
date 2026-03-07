// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "UseSenseSDK",
    platforms: [
        .iOS(.v15)
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
            path: "Sources/UseSense"
        ),
        .testTarget(
            name: "UseSenseSDKTests",
            dependencies: ["UseSenseSDK"],
            path: "Tests/UseSenseTests"
        ),
    ]
)
