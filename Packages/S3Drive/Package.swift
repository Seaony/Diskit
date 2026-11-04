// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "S3Drive", platforms: [.macOS("26.0")],
  products: [.library(name: "S3Drive", targets: ["S3Drive"])],
  dependencies: [.package(path: "../Core")],
  targets: [
    .target(name: "S3Drive", dependencies: [.product(name: "Core", package: "Core")]),
    .testTarget(name: "S3DriveTests", dependencies: ["S3Drive", .product(name: "CoreTestSupport", package: "Core")]),
  ],
  swiftLanguageModes: [.v6])
