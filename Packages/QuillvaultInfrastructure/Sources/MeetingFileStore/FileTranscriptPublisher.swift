import Domain
import Foundation

public actor FileTranscriptPublisher: TranscriptPublisher {
  private struct LoggedFinal: Codable {
    let meetingID: UUID
    let startSeconds: Double
    let endSeconds: Double
    let text: String
  }

  private let replaceFile: @Sendable (URL, URL) throws -> Void

  public init() {
    replaceFile = Self.coordinatedReplace
  }

  init(
    replaceFile: @escaping @Sendable (URL, URL) throws -> Void
  ) {
    self.replaceFile = replaceFile
  }

  public func appendFinal(
    _ segment: TranscriptSegmentCandidate,
    meetingID: MeetingID,
    recordingURL: URL
  ) async throws {
    let directoryURL = try validatedDirectory(
      recordingURL: recordingURL,
      meetingID: meetingID
    )
    let logURL = directoryURL.appending(path: ".transcript-final.jsonl")
    let record = LoggedFinal(
      meetingID: meetingID.rawValue,
      startSeconds: segment.startSeconds,
      endSeconds: segment.endSeconds,
      text: segment.text
    )
    var data = try JSONEncoder.transcriptLog.encode(record)
    data.append(0x0A)

    if !FileManager.default.fileExists(atPath: logURL.path) {
      guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
        throw TranscriptError.publicationFailed
      }
    }
    do {
      let handle = try FileHandle(forWritingTo: logURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      throw TranscriptError.publicationFailed
    }
  }

  public func publish(
    _ revision: TranscriptRevision,
    recordingURL: URL
  ) async throws -> TranscriptRevision {
    let directoryURL = try validatedDirectory(
      recordingURL: recordingURL,
      meetingID: revision.meetingID
    )
    let destinationURL = directoryURL.appending(path: "transcript.md")
    let candidateURL = directoryURL.appending(
      path: ".transcript-\(revision.id).tmp"
    )
    let expected = Data(markdown(for: revision).utf8)

    do {
      guard
        FileManager.default.createFile(
          atPath: candidateURL.path,
          contents: nil
        )
      else {
        throw TranscriptError.publicationFailed
      }
      let handle = try FileHandle(forWritingTo: candidateURL)
      try handle.write(contentsOf: expected)
      try handle.synchronize()
      try handle.close()

      try replaceFile(candidateURL, destinationURL)
      let readback = try Data(contentsOf: destinationURL)
      guard readback == expected else {
        throw TranscriptError.publicationFailed
      }
      return revision
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: candidateURL)
      throw CancellationError()
    } catch {
      try? FileManager.default.removeItem(at: candidateURL)
      throw TranscriptError.publicationFailed
    }
  }

  private func validatedDirectory(
    recordingURL: URL,
    meetingID: MeetingID
  ) throws -> URL {
    guard
      recordingURL.isFileURL,
      recordingURL.lastPathComponent == "recording.m4a",
      FileManager.default.fileExists(atPath: recordingURL.path)
    else {
      throw TranscriptError.publicationFailed
    }
    let directoryURL = recordingURL.deletingLastPathComponent()
    let manifestURL = directoryURL.appending(path: "meeting.json")
    guard
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(MeetingManifest.self, from: data),
      manifest.meetingID == meetingID.rawValue
    else {
      throw TranscriptError.publicationFailed
    }
    return directoryURL
  }

  private func markdown(for revision: TranscriptRevision) -> String {
    var lines = [
      "---",
      "schemaVersion: 1",
      "revisionID: \(revision.id)",
      "contentFingerprint: \(revision.contentFingerprint)",
      "locale: \(revision.localeIdentifier)",
      "audioDurationSeconds: \(formatted(revision.timeline.audioDurationSeconds))",
      "---",
      "",
      "# 文字记录",
      "",
    ]
    lines.append(
      contentsOf: revision.timeline.segments.map {
        TranscriptAnchorFormatter.line(
          for: TranscriptSegmentCandidate(
            startSeconds: $0.startSeconds,
            endSeconds: $0.endSeconds,
            text: $0.text
          )
        )
      }
    )
    lines.append("")
    return lines.joined(separator: "\n")
  }

  private func formatted(_ value: Double) -> String {
    String(
      format: "%.3f",
      locale: Locale(identifier: "en_US_POSIX"),
      value
    )
  }

  private static func coordinatedReplace(
    candidateURL: URL,
    destinationURL: URL
  ) throws {
    var coordinationError: NSError?
    var replacementError: (any Error)?
    NSFileCoordinator().coordinate(
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedDestinationURL in
      do {
        if FileManager.default.fileExists(atPath: coordinatedDestinationURL.path) {
          _ = try FileManager.default.replaceItemAt(
            coordinatedDestinationURL,
            withItemAt: candidateURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
          )
        } else {
          try FileManager.default.moveItem(
            at: candidateURL,
            to: coordinatedDestinationURL
          )
        }
      } catch {
        replacementError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let replacementError {
      throw replacementError
    }
  }
}

extension JSONEncoder {
  fileprivate static var transcriptLog: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
