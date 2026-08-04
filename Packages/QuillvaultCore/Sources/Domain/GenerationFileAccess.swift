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

/// The small amount of metadata needed to protect an existing minutes file
/// from an unconfirmed replacement. The file content remains authoritative;
/// this snapshot is only a comparison boundary for the generation workflow.
public struct GenerationMinutesSnapshot: Equatable, Sendable {
  public let contentFingerprint: String
  public let generationJobID: UUID?
  public let transcriptRevisionID: String?
  public let transcriptFingerprint: String?
  /// Authoritative title from `minutes.md` front matter (may be user-edited).
  public let title: String?
  public let titleUserEdited: Bool

  public init(
    contentFingerprint: String,
    generationJobID: UUID? = nil,
    transcriptRevisionID: String? = nil,
    transcriptFingerprint: String? = nil,
    title: String? = nil,
    titleUserEdited: Bool = false
  ) {
    self.contentFingerprint = contentFingerprint
    self.generationJobID = generationJobID
    self.transcriptRevisionID = transcriptRevisionID
    self.transcriptFingerprint = transcriptFingerprint
    self.title = title
    self.titleUserEdited = titleUserEdited
  }
}

public enum GenerationFileError: Error, Equatable, Sendable {
  case directoryUnavailable
  case meetingUnavailable
  case transcriptUnavailable
  case sourceChanged
  case externalMinutesChanged
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
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) async throws

  func loadMinutesSnapshot(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationMinutesSnapshot?
}

extension GenerationFileAccess {
  public func loadMinutesSnapshot(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationMinutesSnapshot? {
    nil
  }
}
