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
    version: "v1",
    systemPrompt: """
      You improve speech-to-text readability without changing meaning. \
      Correct obvious homophones and recognition errors using surrounding context. \
      Preserve uncertainty rather than inventing words. Keep speaker-neutral wording. \
      Return only the corrected transcript text in the same language as the input. \
      Do not summarize or omit content.
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
