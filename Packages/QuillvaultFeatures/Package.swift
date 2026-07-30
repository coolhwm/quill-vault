// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuillvaultFeatures",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v26),
    // Enables SwiftPM host tests; the distributable app remains iOS-only.
    .macOS(.v14),
  ],
  products: [
    .library(name: "AppNavigation", targets: ["AppNavigation"]),
    .library(name: "HomeFeature", targets: ["HomeFeature"]),
    .library(name: "MeetingsFeature", targets: ["MeetingsFeature"]),
    .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
  ],
  dependencies: [
    .package(path: "../QuillvaultDesignSystem"),
    .package(path: "../QuillvaultCore"),
  ],
  targets: [
    .target(name: "AppNavigation"),
    .target(
      name: "HomeFeature",
      dependencies: [
        .product(name: "DesignSystem", package: "QuillvaultDesignSystem"),
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .target(
      name: "MeetingsFeature",
      dependencies: [
        .product(name: "DesignSystem", package: "QuillvaultDesignSystem"),
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .target(
      name: "SettingsFeature",
      dependencies: [
        .product(name: "DesignSystem", package: "QuillvaultDesignSystem"),
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "AppNavigationTests",
      dependencies: ["AppNavigation"]
    ),
    .testTarget(
      name: "HomeFeatureTests",
      dependencies: [
        "HomeFeature",
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "MeetingsFeatureTests",
      dependencies: [
        "MeetingsFeature",
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "SettingsFeatureTests",
      dependencies: [
        "SettingsFeature",
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
  ]
)
