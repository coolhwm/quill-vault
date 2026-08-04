// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuillvaultFeatures",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v26),
    // App Intents uses the iOS/macOS 26 execution-mode API in host tests.
    .macOS(.v26),
  ],
  products: [
    .library(name: "ActionButtonFeature", targets: ["ActionButtonFeature"]),
    .library(name: "AppNavigation", targets: ["AppNavigation"]),
    .library(name: "HomeFeature", targets: ["HomeFeature"]),
    .library(name: "MeetingsFeature", targets: ["MeetingsFeature"]),
    .library(name: "ProfileFeature", targets: ["ProfileFeature"]),
    .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
  ],
  dependencies: [
    .package(path: "../QuillvaultDesignSystem"),
    .package(path: "../QuillvaultCore"),
  ],
  targets: [
    .target(
      name: "ActionButtonFeature",
      dependencies: [
        .product(name: "Application", package: "QuillvaultCore")
      ]
    ),
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
      ],
      resources: [.process("Resources")]
    ),
    .target(
      name: "ProfileFeature",
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
      name: "ActionButtonFeatureTests",
      dependencies: [
        "ActionButtonFeature",
        .product(name: "Application", package: "QuillvaultCore"),
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
    .testTarget(
      name: "ProfileFeatureTests",
      dependencies: [
        "ProfileFeature",
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
  ]
)
