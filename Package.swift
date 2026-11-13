// swift-tools-version: 6.0
import PackageDescription

// Written by tools/release.sh for v0.9.1; kit/Package.swift is the development copy.
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
            url: "https://github.com/spashii/blend/releases/download/v0.9.1/BlendKitCore-0.9.1.xcframework.zip",
            checksum: "7908fc3cdf51ea81a903e41d2e772b11633411d96efc2b897d72a957452daaed"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"], path: "kit/Sources/BlendKit"),
    ]
)
