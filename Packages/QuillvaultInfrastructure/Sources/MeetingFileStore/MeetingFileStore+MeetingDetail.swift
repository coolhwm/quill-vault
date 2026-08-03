import AVFoundation
import Domain
import Foundation

extension MeetingFileStore: MeetingDetailAccess {
  public func loadMeetingDetail(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    guard
      !meeting.relativeDirectory.contains("/"),
      !meeting.relativeDirectory.contains(".."),
      let root = resolvedRoots[directory.id]
    else {
      throw DirectoryAccessError.directoryMoved
    }
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw DirectoryAccessError.permissionDenied
    }
    let meetingURL = root.url.appending(
      path: meeting.relativeDirectory,
      directoryHint: .isDirectory
    )
    guard isDirectory(meetingURL) else {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw DirectoryAccessError.directoryMoved
    }

    async let transcript = transcriptAsset(
      at: meetingURL.appending(path: "transcript.md")
    )
    async let optimizedTranscript = transcriptAsset(
      at: meetingURL.appending(path: "transcript.optimized.md")
    )
    async let recording = recordingAsset(
      at: meetingURL.appending(path: "recording.m4a"),
      directoryID: directory.id,
      relativeDirectory: meeting.relativeDirectory
    )
    async let minutes = markdownAsset(
      at: meetingURL.appending(path: "minutes.md")
    )
    let detail = await MeetingDetail(
      meeting: meeting,
      transcript: transcript,
      optimizedTranscript: optimizedTranscript,
      recording: recording,
      minutes: minutes
    )
    await dependencies.scopeAccess.stopAccessing(root.url)
    return detail
  }

  private func transcriptAsset(at url: URL) async -> MeetingTranscriptAsset {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .missing
    }
    do {
      guard try dependencies.ubiquitousStatus.isDownloaded(url) else {
        return .downloadRequired
      }
      let markdown = try coordinatedText(at: url)
      return .available(try MeetingTranscriptMarkdownParser().parse(markdown))
    } catch {
      return .unreadable
    }
  }

  private func recordingAsset(
    at url: URL,
    directoryID: AuthoritativeDirectoryID,
    relativeDirectory: String
  ) async -> MeetingRecordingAsset {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .missing
    }
    do {
      guard try dependencies.ubiquitousStatus.isDownloaded(url) else {
        return .downloadRequired
      }
      let duration = try coordinatedRecordingDuration(at: url)
      guard duration.isFinite, duration > 0 else {
        return .unreadable
      }
      return .available(
        MeetingAudioAsset(
          sourceID: audioSourceID(
            directoryID: directoryID,
            relativeDirectory: relativeDirectory
          ),
          durationSeconds: duration
        )
      )
    } catch {
      return .unreadable
    }
  }

  private func markdownAsset(at url: URL) async -> MeetingMarkdownAsset {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .missing
    }
    do {
      guard try dependencies.ubiquitousStatus.isDownloaded(url) else {
        return .downloadRequired
      }
      return .available(
        MeetingMinutesMarkdownParser().parse(
          try coordinatedText(at: url)
        )
      )
    } catch {
      return .unreadable
    }
  }

  private func coordinatedText(at url: URL) throws -> String {
    var coordinationError: NSError?
    var result: Result<String, Error>?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedURL in
      result = Result {
        try String(contentsOf: coordinatedURL, encoding: .utf8)
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

  private func coordinatedRecordingDuration(at url: URL) throws -> Double {
    var coordinationError: NSError?
    var result: Result<Double, Error>?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedURL in
      result = Result {
        let player = try AVAudioPlayer(contentsOf: coordinatedURL)
        guard player.duration.isFinite, player.duration > 0 else {
          throw CocoaError(.fileReadCorruptFile)
        }
        return player.duration
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

  public func beginAudioPlayback(
    sourceID: MeetingAudioSourceID
  ) async throws -> URL {
    guard playbackScopedRoots[sourceID] == nil else {
      throw DirectoryAccessError.coordinationFailed
    }
    let source = try decodeAudioSourceID(sourceID)
    guard let root = resolvedRoots[source.directoryID] else {
      throw DirectoryAccessError.directoryMoved
    }
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw DirectoryAccessError.permissionDenied
    }
    let recordingURL =
      root.url
      .appending(path: source.relativeDirectory, directoryHint: .isDirectory)
      .appending(path: "recording.m4a")
    guard FileManager.default.fileExists(atPath: recordingURL.path) else {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw DirectoryAccessError.directoryMoved
    }
    playbackScopedRoots[sourceID] = root.url
    return recordingURL
  }

  public func endAudioPlayback(sourceID: MeetingAudioSourceID) async {
    guard let root = playbackScopedRoots.removeValue(forKey: sourceID) else {
      return
    }
    await dependencies.scopeAccess.stopAccessing(root)
  }

  private func audioSourceID(
    directoryID: AuthoritativeDirectoryID,
    relativeDirectory: String
  ) -> MeetingAudioSourceID {
    MeetingAudioSourceID(
      rawValue: "\(directoryID.rawValue)\n\(relativeDirectory)"
    )
  }

  private func decodeAudioSourceID(
    _ sourceID: MeetingAudioSourceID
  ) throws -> (
    directoryID: AuthoritativeDirectoryID,
    relativeDirectory: String
  ) {
    let parts = sourceID.rawValue.split(
      separator: "\n",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard
      parts.count == 2,
      !parts[0].isEmpty,
      !parts[1].isEmpty,
      !parts[1].contains("/"),
      !parts[1].contains("..")
    else {
      throw DirectoryAccessError.invalidSelection
    }
    return (
      AuthoritativeDirectoryID(rawValue: String(parts[0])),
      String(parts[1])
    )
  }
}
