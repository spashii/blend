// swift-tools-version: 6.0
import PackageDescription

// Written by tools/release.sh for 0.8.0; kit/Package.swift is the development copy.
// BlendKitCore has no product of its own: SwiftPM would write a libBlendKitCore.a over the
// XCFramework's, so it reaches a host through BlendKit.
let package = Package(
    name: "BlendKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BlendKit", targets: ["BlendKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "BlendKitCore",
            url: "https://github.com/spashii/blend/releases/download/v0.8.0/BlendKitCore-0.8.0.xcframework.zip",
            checksum: "0000000000000000000000000000000000000000000000000000000000000000"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"], path: "kit/Sources/BlendKit"),
    ]
)
