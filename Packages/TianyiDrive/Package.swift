// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TianyiDrive", platforms: [.macOS("26.0")],
  products: [.library(name: "TianyiDrive", targets: ["TianyiDrive"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .target(name: "TianyiDrive", dependencies: [.product(name: "Core", package: "Core")]),
    .testTarget(
      name: "TianyiDriveTests",
      dependencies: ["TianyiDrive", .product(name: "CoreTestSupport", package: "Core")]
    ),
  ],
  swiftLanguageModes: [.v6])
