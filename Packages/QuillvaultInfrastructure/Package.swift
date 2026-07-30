// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuillvaultInfrastructure",
  platforms: [
    .iOS(.v26),
    // Enables SwiftPM host tests; the distributable app remains iOS-only.
    .macOS(.v14),
  ],
  products: [
    .library(name: "AudioCapture", targets: ["AudioCapture"]),
    .library(name: "MeetingFileStore", targets: ["MeetingFileStore"]),
    .library(name: "PersistenceGRDB", targets: ["PersistenceGRDB"]),
    .library(name: "SpeechTranscription", targets: ["SpeechTranscription"]),
  ],
  dependencies: [
    .package(path: "../QuillvaultCore"),
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      exact: "7.10.0"
    ),
  ],
  targets: [
    .target(
      name: "AudioCapture",
      dependencies: [
        .product(name: "Domain", package: "QuillvaultCore")
      ]
    ),
    .target(
      name: "MeetingFileStore",
      dependencies: [
        .product(name: "Domain", package: "QuillvaultCore")
      ]
    ),
    .target(
      name: "PersistenceGRDB",
      dependencies: [
        .product(name: "Domain", package: "QuillvaultCore"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(
      name: "SpeechTranscription",
      dependencies: [
        .product(name: "Domain", package: "QuillvaultCore")
      ]
    ),
    .testTarget(
      name: "AudioCaptureTests",
      dependencies: [
        "AudioCapture",
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "MeetingFileStoreTests",
      dependencies: ["MeetingFileStore", .product(name: "Domain", package: "QuillvaultCore")]
    ),
    .testTarget(
      name: "PersistenceGRDBTests",
      dependencies: [
        "PersistenceGRDB",
        .product(name: "Domain", package: "QuillvaultCore"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "MeetingLibraryIntegrationTests",
      dependencies: [
        "MeetingFileStore",
        "PersistenceGRDB",
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "RecordingIntegrationTests",
      dependencies: [
        "AudioCapture",
        "MeetingFileStore",
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "SpeechTranscriptionTests",
      dependencies: [
        "SpeechTranscription",
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
    .testTarget(
      name: "TranscriptionIntegrationTests",
      dependencies: [
        "MeetingFileStore",
        "PersistenceGRDB",
        .product(name: "Application", package: "QuillvaultCore"),
        .product(name: "Domain", package: "QuillvaultCore"),
      ]
    ),
  ]
)
