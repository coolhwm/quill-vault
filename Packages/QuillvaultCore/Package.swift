// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuillvaultCore",
  platforms: [
    .iOS(.v26),
    // Enables SwiftPM host tests; the distributable app remains iOS-only.
    .macOS(.v14),
  ],
  products: [
    .library(name: "Domain", targets: ["Domain"]),
    .library(name: "Application", targets: ["Application"]),
  ],
  targets: [
    .target(name: "Domain"),
    .target(
      name: "Application",
      dependencies: ["Domain"]
    ),
    .testTarget(
      name: "ApplicationTests",
      dependencies: ["Application", "Domain"]
    ),
  ]
)
