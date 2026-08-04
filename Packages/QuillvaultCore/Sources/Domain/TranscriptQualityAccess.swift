import Foundation

/// Durable optimize-job phase for cold-start resume (walkthrough #47).
public enum TranscriptOptimizeJobState: String, Codable, CaseIterable, Sendable {
  case running
  case failed
}

public struct TranscriptOptimizeJob: Equatable, Codable, Sendable {
  public let meetingID: MeetingID
  public var state: TranscriptOptimizeJobState
  public var progress: Int
  public var updatedAt: Date

  public init(
    meetingID: MeetingID,
    state: TranscriptOptimizeJobState,
    progress: Int = 0,
    updatedAt: Date
  ) {
    self.meetingID = meetingID
    self.state = state
    self.progress = min(max(progress, 0), 99)
    self.updatedAt = updatedAt
  }
}

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

  /// Persist optimize job so home can resume after kill / cold start.
  func saveOptimizeJob(
    _ job: TranscriptOptimizeJob,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws

  func loadOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptOptimizeJob?

  func clearOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws
}

extension TranscriptQualityAccess {
  public func saveOptimizeJob(
    _ job: TranscriptOptimizeJob,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws {}

  public func loadOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptOptimizeJob? { nil }

  public func clearOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws {}
}

public enum TranscriptQualityAccessError: Error, Equatable, Sendable {
  case transcriptUnavailable
  case publicationFailed
  case directoryUnavailable
  /// Model output matched the original (or parse fell back); not a successful optimize.
  case optimizationUnchanged
}
