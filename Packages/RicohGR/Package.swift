// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "RicohGR", platforms: [.macOS("26.0")],
  products: [.library(name: "RicohGR", targets: ["RicohGR"])],
  dependencies: [.package(path: "../Core")],
  targets: [.target(name: "RicohGR", dependencies: [.product(name: "Core", package: "Core")])],
  swiftLanguageModes: [.v6])
