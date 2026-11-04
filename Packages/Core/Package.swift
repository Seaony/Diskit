// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Core", defaultLocalization: "zh-Hans", platforms: [.macOS("26.0")], products: [
    .library(name: "Core", targets: ["Core"]),
    .library(name: "CoreTestSupport", targets: ["CoreTestSupport"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "Core", dependencies: ["CoreNative"], resources: [.process("Resources")]), .target(name: "CoreNative"),
    .target(name: "CoreTestSupport", dependencies: ["Core"]),
    .testTarget(name: "CoreTests", dependencies: ["Core", "CoreNative", "CoreTestSupport"]),
  ], swiftLanguageModes: [.v6])
