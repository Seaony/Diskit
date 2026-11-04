// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PikPakDrive", platforms: [.macOS("26.0")],
  products: [.library(name: "PikPakDrive", targets: ["PikPakDrive"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .target(name: "PikPakDrive", dependencies: [.product(name: "Core", package: "Core")]),
    .testTarget(name: "PikPakDriveTests", dependencies: ["PikPakDrive"]),
  ],
  swiftLanguageModes: [.v6])
