import CryptoKit
import Domain
import Foundation

struct MeetingDirectoryScanner: @unchecked Sendable {
  private let fileManager: FileManager
  private let ubiquitousStatus: any UbiquitousItemStatusChecking

  init(
    fileManager: FileManager = .default,
    ubiquitousStatus: any UbiquitousItemStatusChecking
  ) {
    self.fileManager = fileManager
    self.ubiquitousStatus = ubiquitousStatus
  }

  func scan(_ root: URL) throws -> MeetingDirectoryScan {
    try Task.checkCancellation()
    var coordinationError: NSError?
    var result: Result<MeetingDirectoryScan, Error>?
    NSFileCoordinator().coordinate(
      readingItemAt: root,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedRoot in
      result = Result {
        try scanCoordinatedDirectory(coordinatedRoot)
      }
    }
    if coordinationError != nil {
      throw DirectoryAccessError.coordinationFailed
    }
    guard let result else {
      throw DirectoryAccessError.coordinationFailed
    }
    return try result.get()
  }

  private func scanCoordinatedDirectory(
    _ root: URL
  ) throws -> MeetingDirectoryScan {
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw rootReadError(for: error)
    }

    var meetings: [MeetingIndexEntry] = []
    var fingerprints: [MeetingFileFingerprint] = []
    var diagnostics: [MeetingScanDiagnostic] = []

    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      try Task.checkCancellation()
      guard child.lastPathComponent.hasPrefix("meeting-") else {
        continue
      }
      if isCandidate(child) {
        diagnostics.append(diagnostic(.candidateIgnored, for: child, relativeTo: root))
        continue
      }
      let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true else {
        diagnostics.append(diagnostic(.unreadableEntry, for: child, relativeTo: root))
        continue
      }

      let manifestURL = child.appending(path: "meeting.json")
      guard fileManager.fileExists(atPath: manifestURL.path) else {
        diagnostics.append(diagnostic(.invalidManifest, for: child, relativeTo: root))
        continue
      }
      guard try ubiquitousStatus.isDownloaded(manifestURL) else {
        throw DirectoryAccessError.itemNotDownloaded
      }
      guard
        let manifestData = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(MeetingManifest.self, from: manifestData),
        let createdAt = try? manifest.decodedCreationDate()
      else {
        diagnostics.append(diagnostic(.invalidManifest, for: child, relativeTo: root))
        continue
      }

      let meetingID = MeetingID(rawValue: manifest.meetingID)
      var assets: MeetingAssetPresence = []
      for (asset, fileName, presence) in assetDefinitions {
        try Task.checkCancellation()
        let fileURL = child.appending(path: fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
          continue
        }
        guard try ubiquitousStatus.isDownloaded(fileURL) else {
          throw DirectoryAccessError.itemNotDownloaded
        }
        assets.insert(presence)
        fingerprints.append(
          try fingerprint(
            fileURL,
            asset: asset,
            meetingID: meetingID
          )
        )
      }

      guard !assets.isEmpty else {
        diagnostics.append(diagnostic(.noRecognizedAssets, for: child, relativeTo: root))
        continue
      }
      meetings.append(
        MeetingIndexEntry(
          id: meetingID,
          createdAt: createdAt,
          relativeDirectory: child.lastPathComponent,
          assets: assets
        )
      )
    }

    return MeetingDirectoryScan(
      meetings: meetings,
      fingerprints: fingerprints,
      diagnostics: diagnostics
    )
  }

  private var assetDefinitions: [(MeetingAsset, String, MeetingAssetPresence)] {
    [
      (.recording, "recording.m4a", .recording),
      (.transcript, "transcript.md", .transcript),
      (.minutes, "minutes.md", .minutes),
    ]
  }

  private func isCandidate(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name.hasSuffix(".candidate")
      || name.hasSuffix(".partial")
      || name.hasSuffix(".tmp")
  }

  private func fingerprint(
    _ url: URL,
    asset: MeetingAsset,
    meetingID: MeetingID
  ) throws -> MeetingFileFingerprint {
    let values = try url.resourceValues(forKeys: [
      .fileSizeKey,
      .contentModificationDateKey,
    ])
    guard
      let size = values.fileSize,
      let modifiedAt = values.contentModificationDate
    else {
      throw DirectoryAccessError.unreadableDirectory
    }
    let input = "\(asset.rawValue)|\(size)|\(modifiedAt.timeIntervalSince1970)"
    return MeetingFileFingerprint(
      meetingID: meetingID,
      asset: asset,
      byteCount: Int64(size),
      modifiedAt: modifiedAt,
      opaqueDigest: sha256(input)
    )
  }

  private func diagnostic(
    _ code: MeetingScanDiagnosticCode,
    for url: URL,
    relativeTo root: URL
  ) -> MeetingScanDiagnostic {
    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
    return MeetingScanDiagnostic(
      code: code,
      relativePathDigest: sha256(relative)
    )
  }

  private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func rootReadError(for error: Error) -> DirectoryAccessError {
    let cocoaError = error as? CocoaError
    if cocoaError?.code == .fileReadNoPermission {
      return .permissionDenied
    }
    if cocoaError?.code == .fileNoSuchFile
      || cocoaError?.code == .fileReadNoSuchFile
    {
      return .directoryMoved
    }
    return .unreadableDirectory
  }
}
