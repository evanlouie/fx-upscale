// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "fx-upscale",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .executable(name: "fx-upscale", targets: ["fx-upscale"]),
        .library(name: "Upscaling", targets: ["Upscaling"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/Finnvoor/SwiftTUI.git", from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-testing.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "fx-upscale",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
                "Upscaling"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "Upscaling",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UpscalingTests",
            dependencies: [
                "Upscaling",
                .product(name: "Testing", package: "swift-testing")
            ],
            resources: [.process("Resources")]
        )
    ]
)
