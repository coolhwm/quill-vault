import Foundation

/// User preference for optional post-recording transcript quality optimization.
public struct TranscriptQualityPreferences: Equatable, Sendable {
  public var isEnabled: Bool

  public init(isEnabled: Bool = false) {
    self.isEnabled = isEnabled
  }
}

public enum TranscriptVersionKind: String, Codable, CaseIterable, Sendable {
  case original
  case optimized
}

/// Independent optimized transcript asset metadata. The original `transcript.md`
/// remains immutable evidence.
public struct TranscriptVersionMetadata: Equatable, Codable, Sendable {
  public let kind: TranscriptVersionKind
  public let parentKind: TranscriptVersionKind
  public let strategyID: String
  public let strategyVersion: String
  public let modelName: String?
  public let createdAt: Date

  public init(
    kind: TranscriptVersionKind = .optimized,
    parentKind: TranscriptVersionKind = .original,
    strategyID: String,
    strategyVersion: String,
    modelName: String?,
    createdAt: Date
  ) {
    self.kind = kind
    self.parentKind = parentKind
    self.strategyID = strategyID
    self.strategyVersion = strategyVersion
    self.modelName = modelName
    self.createdAt = createdAt
  }
}

/// Language-agnostic offline optimization strategy resource.
public struct TranscriptQualityStrategy: Equatable, Sendable {
  public let id: String
  public let version: String
  public let systemPrompt: String

  public init(id: String, version: String, systemPrompt: String) {
    self.id = id
    self.version = version
    self.systemPrompt = systemPrompt
  }

  public static let offlineV1 = TranscriptQualityStrategy(
    id: "offline-readability",
    version: "v2",
    systemPrompt: """
      You clean speech-to-text transcripts for human reading while preserving meaning and coverage. \
      Aggressively fix: homophones, wrong characters from ASR, broken words, missing punctuation, \
      run-on speech, and filler noise (嗯/啊/那个) when they do not carry meaning. \
      Improve sentence boundaries and light grammar so each line is readable. \
      Do NOT summarize, drop topics, reorder segments, or invent facts not supported by context. \
      Keep the same language as the input. \
      Output format: one corrected line per input line when lines are provided; otherwise plain paragraphs. \
      Return only corrected transcript text — no preface, no markdown fences, no commentary.
      """
  )
}

/// Future real-time seam: incremental optimization over a bounded context window.
public protocol IncrementalTranscriptQualityPort: Sendable {
  func optimize(
    segment: TranscriptSegmentCandidate,
    context: [TranscriptSegmentCandidate]
  ) async throws -> TranscriptSegmentCandidate
}
