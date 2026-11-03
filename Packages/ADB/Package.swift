// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ADB", platforms: [.macOS("26.0")], products: [.library(name: "ADB", targets: ["ADB"])],
  dependencies: [.package(path: "../Core")],
  targets: [.target(name: "ADB", dependencies: [.product(name: "Core", package: "Core")])],
  swiftLanguageModes: [.v6])
