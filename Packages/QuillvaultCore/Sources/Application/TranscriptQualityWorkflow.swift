import Domain
import Foundation

public protocol TranscriptQualityUseCase: Sendable {
  func optimize(
    timeline: TranscriptTimeline,
    localeIdentifier: String
  ) async throws -> (timeline: TranscriptTimeline, metadata: TranscriptVersionMetadata)

  /// Loads the original transcript, optimizes offline, and publishes
  /// `transcript.optimized.md` without modifying `transcript.md`.
  /// Persists a durable running/failed job so cold start can resume.
  func optimizeAndPublish(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptVersionMetadata

  func loadOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptOptimizeJob?
}

extension TranscriptQualityUseCase {
  public func loadOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptOptimizeJob? {
    nil
  }
}

// Re-export access errors for Application callers.
public typealias TranscriptQualityError = TranscriptQualityAccessError

/// Offline post-recording transcript quality optimization. Original transcript
/// assets stay immutable; optimized results are published as a sibling file.
public actor TranscriptQualityWorkflow: TranscriptQualityUseCase {
  private let profiles: any ModelProfileExecutionAccess
  private let provider: any AIProvider
  private let access: (any TranscriptQualityAccess)?
  private let strategy: TranscriptQualityStrategy
  private let now: @Sendable () -> Date

  public init(
    profiles: any ModelProfileExecutionAccess,
    provider: any AIProvider,
    access: (any TranscriptQualityAccess)? = nil,
    strategy: TranscriptQualityStrategy = .offlineV1,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.profiles = profiles
    self.provider = provider
    self.access = access
    self.strategy = strategy
    self.now = now
  }

  public func optimize(
    timeline: TranscriptTimeline,
    localeIdentifier: String
  ) async throws -> (timeline: TranscriptTimeline, metadata: TranscriptVersionMetadata) {
    let execution = try await profiles.currentExecutionProfile()
    let sourceText = timeline.segments.map {
      TranscriptAnchorFormatter.line(
        for: TranscriptSegmentCandidate(
          startSeconds: $0.startSeconds,
          endSeconds: $0.endSeconds,
          text: $0.text
        )
      )
    }.joined(separator: "\n")

    let request = AIRequest(
      systemPrompt: strategy.systemPrompt,
      userPrompt: """
        Improve the readability of this transcript. Keep the same line anchors \
        and order. Locale: \(localeIdentifier).

        \(sourceText)
        """,
      idempotencyKey:
        "transcript-quality-\(strategy.id)-\(strategy.version)-\(timeline.audioDurationSeconds)"
    )
    var output = ""
    var completed = false
    for try await event in provider.generate(
      request,
      profile: execution.snapshot,
      apiKey: execution.apiKey
    ) {
      try Task.checkCancellation()
      switch event {
      case .textDelta(let delta):
        output.append(delta)
      case .completed:
        completed = true
      }
    }
    guard completed else {
      throw AIProviderError.invalidResponse
    }
    let optimized = try parseOptimizedTimeline(
      from: output.trimmingCharacters(in: .whitespacesAndNewlines),
      fallback: timeline
    )
    // Parse fallback / no-op model output must not count as a successful optimize.
    guard optimized.segments.map(\.text) != timeline.segments.map(\.text) else {
      throw TranscriptQualityAccessError.optimizationUnchanged
    }
    let metadata = TranscriptVersionMetadata(
      strategyID: strategy.id,
      strategyVersion: strategy.version,
      modelName: execution.snapshot.model,
      createdAt: now()
    )
    return (optimized, metadata)
  }

  public func optimizeAndPublish(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptVersionMetadata {
    guard let access else {
      throw TranscriptQualityAccessError.publicationFailed
    }
    let runningJob = TranscriptOptimizeJob(
      meetingID: meeting.id,
      state: .running,
      progress: 5,
      updatedAt: now()
    )
    try? await access.saveOptimizeJob(
      runningJob,
      in: directory,
      meeting: meeting
    )
    do {
      let original = try await access.loadOriginalTranscript(
        in: directory,
        meeting: meeting
      )
      let beforeFingerprint = try await access.originalTranscriptFingerprint(
        in: directory,
        meeting: meeting
      )
      try? await access.saveOptimizeJob(
        TranscriptOptimizeJob(
          meetingID: meeting.id,
          state: .running,
          progress: 40,
          updatedAt: now()
        ),
        in: directory,
        meeting: meeting
      )
      let result = try await optimize(
        timeline: original.timeline,
        localeIdentifier: original.localeIdentifier
      )
      let afterFingerprint = try await access.originalTranscriptFingerprint(
        in: directory,
        meeting: meeting
      )
      // Guard: original asset must remain unchanged after optimization.
      guard beforeFingerprint == afterFingerprint else {
        throw TranscriptQualityAccessError.publicationFailed
      }
      let optimizedRevision = TranscriptRevision(
        meetingID: original.meetingID,
        localeIdentifier: original.localeIdentifier,
        timeline: result.timeline
      )
      try? await access.saveOptimizeJob(
        TranscriptOptimizeJob(
          meetingID: meeting.id,
          state: .running,
          progress: 85,
          updatedAt: now()
        ),
        in: directory,
        meeting: meeting
      )
      try await access.publishOptimized(
        optimizedRevision,
        in: directory,
        meeting: meeting,
        metadata: result.metadata
      )
      let stillOriginal = try await access.originalTranscriptFingerprint(
        in: directory,
        meeting: meeting
      )
      guard stillOriginal == beforeFingerprint else {
        throw TranscriptQualityAccessError.publicationFailed
      }
      try? await access.clearOptimizeJob(in: directory, meeting: meeting)
      return result.metadata
    } catch {
      try? await access.saveOptimizeJob(
        TranscriptOptimizeJob(
          meetingID: meeting.id,
          state: .failed,
          progress: 0,
          updatedAt: now()
        ),
        in: directory,
        meeting: meeting
      )
      throw error
    }
  }

  public func loadOptimizeJob(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptOptimizeJob? {
    try await access?.loadOptimizeJob(in: directory, meeting: meeting)
  }

  private func parseOptimizedTimeline(
    from output: String,
    fallback: TranscriptTimeline
  ) throws -> TranscriptTimeline {
    // Prefer line-aligned replacements when the model keeps segment structure.
    // Accept common wrappers (fences, bullet prefixes) without inventing text.
    var body =
      output
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("```") {
      let lines = body.components(separatedBy: "\n")
      body = lines.dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
    }
    let lines =
      body
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { line in
        guard !line.isEmpty else { return false }
        if line.hasPrefix("#") { return false }
        if line.hasPrefix("---") { return false }
        return true
      }
    // Prefer exact segment-count match; if model returns more lines, take first N.
    guard lines.count >= fallback.segments.count, !fallback.segments.isEmpty else {
      return fallback
    }
    var candidates: [TranscriptSegmentCandidate] = []
    for (index, segment) in fallback.segments.enumerated() {
      var line = lines[index]
      if line.hasPrefix("- ") {
        line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      }
      let text: String
      if let close = line.lastIndex(of: "]"),
        close < line.endIndex
      {
        let after = line.index(after: close)
        text = String(line[after...]).trimmingCharacters(in: .whitespaces)
      } else {
        text = line
      }
      guard !text.isEmpty else {
        return fallback
      }
      candidates.append(
        TranscriptSegmentCandidate(
          startSeconds: segment.startSeconds,
          endSeconds: segment.endSeconds,
          text: text
        )
      )
    }
    return try TranscriptTimeline.normalizing(
      candidates,
      audioDurationSeconds: fallback.audioDurationSeconds
    )
  }
}

/// No-op incremental port reserved for real-time quality optimization.
public struct PassthroughIncrementalTranscriptQuality:
  IncrementalTranscriptQualityPort
{
  public init() {}

  public func optimize(
    segment: TranscriptSegmentCandidate,
    context: [TranscriptSegmentCandidate]
  ) async throws -> TranscriptSegmentCandidate {
    segment
  }
}
