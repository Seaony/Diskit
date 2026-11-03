// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Quark", platforms: [.macOS("26.0")],
  products: [.library(name: "Quark", targets: ["Quark"])],
  dependencies: [.package(path: "../Core")],
  targets: [.target(name: "Quark", dependencies: [.product(name: "Core", package: "Core")])],
  swiftLanguageModes: [.v6])
