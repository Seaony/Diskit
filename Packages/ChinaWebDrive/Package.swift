// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ChinaWebDrive",
  platforms: [.macOS("26.0")],
  products: [.library(name: "ChinaWebDrive", targets: ["ChinaWebDrive"])],
  dependencies: [
    .package(path: "../Core"),
    .package(
      url: "https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2.git",
      exact: "0.4.0"
    ),
  ],
  targets: [
    .target(
      name: "ChinaWebDrive",
      dependencies: [
        .product(name: "Core", package: "Core"),
        .product(name: "AlibabaCloudOSS", package: "alibabacloud-oss-swift-sdk-v2"),
      ]
    ),
    .testTarget(name: "ChinaWebDriveTests", dependencies: ["ChinaWebDrive"]),
  ],
  swiftLanguageModes: [.v6]
)
