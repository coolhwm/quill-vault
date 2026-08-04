import Foundation

/// Selects the transcript used for minutes generation and expiry checks.
/// Prefer optimized readability version when present; otherwise original.
public enum GenerationPrimaryTranscript {
  public static let originalFileName = "transcript.md"
  public static let optimizedFileName = "transcript.optimized.md"

  public struct Candidate: Equatable, Sendable {
    public let revisionID: String
    public let contentFingerprint: String
    public let timeline: TranscriptTimeline
    public let localeIdentifier: String
    public let kind: TranscriptVersionKind

    public init(
      revisionID: String,
      contentFingerprint: String,
      timeline: TranscriptTimeline,
      localeIdentifier: String,
      kind: TranscriptVersionKind
    ) {
      self.revisionID = revisionID
      self.contentFingerprint = contentFingerprint
      self.timeline = timeline
      self.localeIdentifier = localeIdentifier
      self.kind = kind
    }
  }

  /// Prefer optimized when available; fall back to original.
  public static func prefer(
    original: Candidate?,
    optimized: Candidate?
  ) -> Candidate? {
    optimized ?? original
  }

  public static func candidate(
    meetingID: MeetingID,
    localeIdentifier: String,
    timeline: TranscriptTimeline,
    kind: TranscriptVersionKind
  ) -> Candidate {
    let revision = TranscriptRevision(
      meetingID: meetingID,
      localeIdentifier: localeIdentifier,
      timeline: timeline
    )
    return Candidate(
      revisionID: revision.id,
      contentFingerprint: revision.contentFingerprint,
      timeline: timeline,
      localeIdentifier: localeIdentifier,
      kind: kind
    )
  }
}
