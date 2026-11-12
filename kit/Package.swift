// swift-tools-version: 6.0
import PackageDescription

// The development package: the XCFramework is built next to it by CMake (tools/build.sh,
// or `cmake --build build --target BlendKitCore`) and is git-ignored. The package at the
// repository root is what other repositories resolve; it points the same targets at the
// release asset. BlendKitCore has no product of its own: SwiftPM would write a
// libBlendKitCore.a over the XCFramework's, so it reaches a host through BlendKit.
let package = Package(
    name: "BlendKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BlendKit", targets: ["BlendKit"]),
    ],
    targets: [
        .binaryTarget(name: "BlendKitCore", path: "BlendKitCore.xcframework"),
        .target(name: "BlendKit", dependencies: ["BlendKitCore"]),
        .testTarget(name: "BlendKitTests", dependencies: ["BlendKit"]),
    ]
)
