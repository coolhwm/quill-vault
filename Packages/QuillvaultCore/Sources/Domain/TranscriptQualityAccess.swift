import Foundation

/// File-system seam for durable optimized transcript versions.
public protocol TranscriptQualityAccess: Sendable {
  func publishOptimized(
    _ revision: TranscriptRevision,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    metadata: TranscriptVersionMetadata
  ) async throws

  func loadOriginalTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision

  func loadOptimizedTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision?

  /// Returns true when `transcript.md` still matches the expected original fingerprint.
  func originalTranscriptFingerprint(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> String?
}

public enum TranscriptQualityAccessError: Error, Equatable, Sendable {
  case transcriptUnavailable
  case publicationFailed
  case directoryUnavailable
  /// Model output matched the original (or parse fell back); not a successful optimize.
  case optimizationUnchanged
}
