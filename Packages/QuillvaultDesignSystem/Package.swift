// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuillvaultDesignSystem",
  platforms: [
    .iOS(.v26),
    // Enables SwiftPM host tests; the distributable app remains iOS-only.
    .macOS(.v14),
  ],
  products: [
    .library(name: "DesignSystem", targets: ["DesignSystem"])
  ],
  targets: [
    .target(name: "DesignSystem")
  ]
)
