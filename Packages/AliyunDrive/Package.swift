// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AliyunDrive", platforms: [.macOS("26.0")],
  products: [.library(name: "AliyunDrive", targets: ["AliyunDrive"])],
  dependencies: [.package(path: "../Core")],
  targets: [.target(name: "AliyunDrive", dependencies: [.product(name: "Core", package: "Core")])],
  swiftLanguageModes: [.v6])
