// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DevTool", defaultLocalization: "zh-Hans", platforms: [.macOS("26.0")],
  products: [
    .executable(name: "diskit-dev", targets: ["DevTool"]),
    .library(name: "DevToolSupport", targets: ["DevToolSupport"]),
  ],
  dependencies: [
    .package(path: "../Core"), .package(path: "../ADB"),
    .package(path: "../Quark"), .package(path: "../S3Drive"),
    .package(path: "../CameraUSB"),
    .package(path: "../PikPakDrive"), .package(path: "../LanzouDrive"),
    .package(path: "../TianyiDrive"), .package(path: "../ChinaWebDrive"),
  ],
  targets: [
    .executableTarget(name: "DevTool", dependencies: ["DevToolLauncher"]),
    .target(name: "DevToolLauncher", resources: [.process("Resources")]),
    .target(
      name: "DevToolSupport",
      dependencies: [
        .product(name: "Core", package: "Core"), .product(name: "ADB", package: "ADB"),
        .product(name: "Quark", package: "Quark"),
        .product(name: "S3Drive", package: "S3Drive"),
        .product(name: "CameraUSB", package: "CameraUSB"),
        .product(name: "PikPakDrive", package: "PikPakDrive"),
        .product(name: "LanzouDrive", package: "LanzouDrive"),
        .product(name: "TianyiDrive", package: "TianyiDrive"),
        .product(name: "ChinaWebDrive", package: "ChinaWebDrive"),
      ]),
    .testTarget(name: "DevToolTests", dependencies: ["DevToolSupport", "DevToolLauncher"]),
  ], swiftLanguageModes: [.v6])
