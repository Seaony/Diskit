// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CloudDrive", platforms: [.macOS("26.0")],
  products: [.library(name: "CloudDrive", targets: ["CloudDrive"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .target(name: "CloudDrive", dependencies: [.product(name: "Core", package: "Core")]),
    .testTarget(name: "CloudDriveTests", dependencies: ["CloudDrive"]),
  ],
  swiftLanguageModes: [.v6])
