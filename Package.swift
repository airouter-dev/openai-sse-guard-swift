// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenAISSEGuard",
    products: [
        .library(
            name: "OpenAISSEGuard",
            targets: ["OpenAISSEGuard"]
        )
    ],
    targets: [
        .target(name: "OpenAISSEGuard"),
        .testTarget(
            name: "OpenAISSEGuardTests",
            dependencies: ["OpenAISSEGuard"]
        )
    ]
)
