// swift-tools-version: 6.0
import PackageDescription

// Written by tools/release.sh for v0.10.2-pre.143; kit/Package.swift is the development copy.
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
            url: "https://github.com/spashii/blend/releases/download/v0.10.2-pre.143/BlendKitCore-0.10.2.xcframework.zip",
            checksum: "5a835b04aaf8b3763b0826244f7a30c4112761211de8cf8dd39a2be2c02d4ee2"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"], path: "kit/Sources/BlendKit"),
    ]
)
