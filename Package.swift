// swift-tools-version: 6.0
import PackageDescription

// Written by tools/release.sh for v0.10.0; kit/Package.swift is the development copy.
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
            url: "https://github.com/spashii/blend/releases/download/v0.10.0/BlendKitCore-0.10.0.xcframework.zip",
            checksum: "fb404b5badeece3a8c0989b633064d6cbc3c63ee087cb5f6e4378e4a8f4077e7"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"], path: "kit/Sources/BlendKit"),
    ]
)
