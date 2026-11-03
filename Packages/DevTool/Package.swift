// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DevTool", platforms: [.macOS("26.0")],
  products: [.executable(name: "kayoi-dev", targets: ["DevTool"])],
  dependencies: [
    .package(path: "../Core"), .package(path: "../ADB"), .package(path: "../RicohGR"),
    .package(path: "../AliyunDrive"), .package(path: "../Quark"),
  ],
  targets: [
    .executableTarget(
      name: "DevTool",
      dependencies: [
        .product(name: "Core", package: "Core"), .product(name: "ADB", package: "ADB"),
        .product(name: "RicohGR", package: "RicohGR"),
        .product(name: "AliyunDrive", package: "AliyunDrive"),
        .product(name: "Quark", package: "Quark"),
      ])
  ], swiftLanguageModes: [.v6])
