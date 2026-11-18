// swift-tools-version: 6.0
import PackageDescription

// Written by tools/release.sh for v0.10.2-pre.146; kit/Package.swift is the development copy.
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
            url: "https://github.com/spashii/blend/releases/download/v0.10.2-pre.146/BlendKitCore-0.10.2.xcframework.zip",
            checksum: "de8b0f42090877f01196b560f73de9f08376433320a5dcb01f33988c7e71d589"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"], path: "kit/Sources/BlendKit"),
    ]
)
