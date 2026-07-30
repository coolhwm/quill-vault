import AVFAudio
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
    var searchDocuments: [MeetingSearchDocument] = []

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
      var title: String?
      var durationSeconds: Double?
      var modelName: String?
      var searchableSummary = ""
      var searchableTranscript = ""
      var hasInvalidMarkdown = false
      var meetingFingerprints: [MeetingFileFingerprint] = []
      for (asset, fileName, presence) in assetDefinitions {
        try Task.checkCancellation()
        let fileURL = child.appending(path: fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
          continue
        }
        assets.insert(presence)
        guard try ubiquitousStatus.isDownloaded(fileURL) else {
          throw DirectoryAccessError.itemNotDownloaded
        }
        switch asset {
        case .recording:
          durationSeconds = durationSeconds ?? recordingDuration(at: fileURL)
        case .transcript:
          guard
            let markdown = fullText(at: fileURL),
            let timeline = try? MeetingTranscriptMarkdownParser().parse(markdown)
          else {
            hasInvalidMarkdown = true
            continue
          }
          durationSeconds =
            MeetingTranscriptMarkdownParser.audioDuration(from: markdown)
            ?? durationSeconds
          searchableTranscript = timeline.segments.map(\.text).joined(separator: "\n")
        case .minutes:
          guard let markdown = fullText(at: fileURL) else {
            hasInvalidMarkdown = true
            continue
          }
          let content = MeetingMinutesMarkdownParser().parse(markdown)
          guard
            !content.summaryMarkdown.isEmpty
              || content.diagramSource?.isEmpty == false
          else {
            hasInvalidMarkdown = true
            continue
          }
          let metadata = minutesMetadata(in: markdown)
          title = metadata.title
          modelName = metadata.modelName
          searchableSummary = content.summaryMarkdown
        }
        meetingFingerprints.append(
          try fingerprint(
            fileURL,
            asset: asset,
            meetingID: meetingID
          )
        )
      }

      guard !hasInvalidMarkdown else {
        diagnostics.append(diagnostic(.invalidMarkdown, for: child, relativeTo: root))
        continue
      }
      guard !assets.isEmpty else {
        diagnostics.append(diagnostic(.noRecognizedAssets, for: child, relativeTo: root))
        continue
      }
      fingerprints.append(contentsOf: meetingFingerprints)
      meetings.append(
        MeetingIndexEntry(
          id: meetingID,
          createdAt: createdAt,
          relativeDirectory: child.lastPathComponent,
          assets: assets,
          title: title,
          durationSeconds: durationSeconds,
          modelName: modelName
        )
      )
      searchDocuments.append(
        MeetingSearchDocument(
          meetingID: meetingID,
          title: title ?? "",
          summary: searchableSummary,
          transcript: searchableTranscript
        )
      )
    }

    return MeetingDirectoryScan(
      meetings: meetings,
      fingerprints: fingerprints,
      diagnostics: diagnostics,
      searchDocuments: searchDocuments
    )
  }

  private func recordingDuration(at url: URL) -> Double? {
    guard
      let player = try? AVAudioPlayer(contentsOf: url),
      player.duration.isFinite,
      player.duration > 0
    else {
      return nil
    }
    return player.duration
  }

  private func minutesMetadata(
    in text: String?
  ) -> (title: String?, modelName: String?) {
    guard let text else {
      return (nil, nil)
    }
    return (
      frontMatterValue(named: "title", in: text),
      frontMatterValue(named: "model", in: text)
    )
  }

  private func fullText(at url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  private func frontMatterValue(named name: String, in text: String) -> String? {
    guard text.hasPrefix("---") else {
      return nil
    }
    let prefix = "\(name):"
    guard
      let line = text.split(separator: "\n").dropFirst().prefix(while: {
        $0.trimmingCharacters(in: .whitespaces) != "---"
      }).first(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
      })
    else {
      return nil
    }
    let value = line.trimmingCharacters(in: .whitespaces)
      .dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return value.isEmpty ? nil : value
  }

  private func filePrefixText(at url: URL) -> String? {
    guard
      let handle = try? FileHandle(forReadingFrom: url)
    else {
      return nil
    }
    defer {
      try? handle.close()
    }
    guard
      let prefix = try? handle.read(upToCount: 4_096),
      let text = String(data: prefix, encoding: .utf8)
    else {
      return nil
    }
    return text
  }

  private var assetDefinitions: [(MeetingAsset, String, MeetingAssetPresence)] {
    [
      (.transcript, "transcript.md", .transcript),
      (.minutes, "minutes.md", .minutes),
      (.recording, "recording.m4a", .recording),
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
    let input: String
    switch asset {
    case .transcript, .minutes:
      guard let data = try? Data(contentsOf: url) else {
        throw DirectoryAccessError.unreadableDirectory
      }
      let contentDigest = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
      input = "\(asset.rawValue)|\(contentDigest)"
    case .recording:
      input = "\(asset.rawValue)|\(size)|\(modifiedAt.timeIntervalSince1970)"
    }
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
