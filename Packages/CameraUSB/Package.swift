// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CameraUSB", platforms: [.macOS("26.0")],
  products: [.library(name: "CameraUSB", targets: ["CameraUSB"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .target(name: "CameraUSB", dependencies: [.product(name: "Core", package: "Core")]),
    .testTarget(name: "CameraUSBTests", dependencies: ["CameraUSB", .product(name: "CoreTestSupport", package: "Core")]),
  ],
  swiftLanguageModes: [.v6])
