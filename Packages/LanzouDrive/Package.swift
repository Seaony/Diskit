// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LanzouDrive", platforms: [.macOS("26.0")],
  products: [.library(name: "LanzouDrive", targets: ["LanzouDrive"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .target(name: "LanzouDrive", dependencies: [.product(name: "Core", package: "Core")]),
    .testTarget(name: "LanzouDriveTests", dependencies: ["LanzouDrive"]),
  ],
  swiftLanguageModes: [.v6])
