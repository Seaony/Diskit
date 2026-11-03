// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DevTool", platforms: [.macOS("26.0")],
  products: [.executable(name: "kayoi-dev", targets: ["DevTool"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .executableTarget(name: "DevTool", dependencies: [.product(name: "Core", package: "Core")])
  ], swiftLanguageModes: [.v6])
