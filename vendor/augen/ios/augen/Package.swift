// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "augen",
    platforms: [
        // Bumped from 13.0: the fork-local textured-plane path
        // (AugenARView.swift's loadTexturedPlane) uses UnlitMaterial and
        // TextureResource.generate(from:withName:options:), both iOS 15+
        // RealityKit APIs.
        .iOS("15.0")
    ],
    products: [
        .library(name: "augen", targets: ["augen"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "augen",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
