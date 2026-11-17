// swift-tools-version: 6.0
import PackageDescription

// Written by tools/release.sh for v0.10.1; kit/Package.swift is the development copy.
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
            url: "https://github.com/spashii/blend/releases/download/v0.10.1/BlendKitCore-0.10.1.xcframework.zip",
            checksum: "bc3d431fba015b1d6736853f540392cd508684e74f938f62e3201c74901c5dde"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"], path: "kit/Sources/BlendKit"),
    ]
)
