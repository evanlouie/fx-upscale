// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "fx-upscale",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "fx-upscale", targets: ["fx-upscale"]),
    .library(name: "Upscaling", targets: ["Upscaling"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
  ],
  targets: [
    .executableTarget(
      name: "fx-upscale",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        "Upscaling",
      ]
    ),
    .target(
      name: "Upscaling"
    ),
    .testTarget(
      name: "UpscalingTests",
      dependencies: ["Upscaling"],
      resources: [.process("Resources")]
    ),
  ]
)
