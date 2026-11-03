// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Core", platforms: [.macOS("26.0")], products: [.library(name: "Core", targets: ["Core"])],
  dependencies: [],
  targets: [
    .target(name: "Core", dependencies: ["CoreNative"]), .target(name: "CoreNative"),
    .testTarget(name: "CoreTests", dependencies: ["Core"]),
  ], swiftLanguageModes: [.v6])
