import Foundation

public struct GenerationTranscriptSource: Equatable, Sendable {
  public let revision: TranscriptRevision

  public init(revision: TranscriptRevision) {
    self.revision = revision
  }

  public var promptText: String {
    revision.timeline.segments.map {
      TranscriptAnchorFormatter.line(
        for: TranscriptSegmentCandidate(
          startSeconds: $0.startSeconds,
          endSeconds: $0.endSeconds,
          text: $0.text
        )
      )
    }
    .joined(separator: "\n")
  }
}

public enum GenerationFileError: Error, Equatable, Sendable {
  case directoryUnavailable
  case meetingUnavailable
  case transcriptUnavailable
  case sourceChanged
  case publicationFailed
}

public protocol GenerationFileAccess: Sendable {
  func loadTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationTranscriptSource

  func publishMinutes(
    _ markdown: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String
  ) async throws
}
