import CryptoKit
import Foundation

/// The deterministic unit of work sent to a model during minutes generation.
public struct GenerationChunk: Codable, Equatable, Sendable {
  public let index: Int
  public let startSeconds: Double
  public let endSeconds: Double
  public let promptText: String
  public let inputFingerprint: String

  public init(
    index: Int,
    startSeconds: Double,
    endSeconds: Double,
    promptText: String,
    inputFingerprint: String
  ) {
    self.index = index
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
    self.promptText = promptText
    self.inputFingerprint = inputFingerprint
  }
}

public struct GenerationChunkPlan: Codable, Equatable, Sendable {
  public static let currentVersion = "v1"

  public let version: String
  public let chunks: [GenerationChunk]

  public init(
    version: String = GenerationChunkPlan.currentVersion,
    chunks: [GenerationChunk]
  ) {
    self.version = version
    self.chunks = chunks
  }

  public static func make(
    from revision: TranscriptRevision,
    maxCharactersPerChunk: Int = 8_000,
    maxDurationSeconds: Double = 600
  ) -> Self {
    let characterLimit = max(1, maxCharactersPerChunk)
    let durationLimit = max(1, maxDurationSeconds)
    var chunks: [GenerationChunk] = []
    var lines: [String] = []
    var startSeconds = 0.0
    var endSeconds = 0.0
    var characterCount = 0

    func appendChunk(
      to chunks: inout [GenerationChunk],
      lines: inout [String],
      startSeconds: inout Double,
      endSeconds: inout Double,
      characterCount: inout Int
    ) {
      guard !lines.isEmpty else { return }
      let promptText = lines.joined(separator: "\n")
      let fingerprint = Self.sha256(
        "\(Self.canonicalSeconds(startSeconds))|\(Self.canonicalSeconds(endSeconds))|\(promptText)"
      )
      chunks.append(
        GenerationChunk(
          index: chunks.count,
          startSeconds: startSeconds,
          endSeconds: endSeconds,
          promptText: promptText,
          inputFingerprint: fingerprint
        )
      )
      lines.removeAll(keepingCapacity: true)
      startSeconds = 0
      endSeconds = 0
      characterCount = 0
    }

    for segment in revision.timeline.segments {
      let line = TranscriptAnchorFormatter.line(
        for: TranscriptSegmentCandidate(
          startSeconds: segment.startSeconds,
          endSeconds: segment.endSeconds,
          text: segment.text
        )
      )
      let segmentDuration = max(0, segment.endSeconds - segment.startSeconds)
      let wouldExceedCharacters =
        !lines.isEmpty
        && characterCount + line.count > characterLimit
      let wouldExceedDuration =
        !lines.isEmpty
        && segment.endSeconds - startSeconds > durationLimit

      if wouldExceedCharacters || wouldExceedDuration {
        appendChunk(
          to: &chunks,
          lines: &lines,
          startSeconds: &startSeconds,
          endSeconds: &endSeconds,
          characterCount: &characterCount
        )
      }

      if lines.isEmpty {
        startSeconds = segment.startSeconds
      }
      lines.append(line)
      endSeconds = max(endSeconds, segment.endSeconds)
      characterCount += line.count

      // A single oversized segment remains intact. Splitting inside an anchored
      // segment would make resume fingerprints depend on Unicode slicing details.
      if segmentDuration > durationLimit {
        appendChunk(
          to: &chunks,
          lines: &lines,
          startSeconds: &startSeconds,
          endSeconds: &endSeconds,
          characterCount: &characterCount
        )
      }
    }

    appendChunk(
      to: &chunks,
      lines: &lines,
      startSeconds: &startSeconds,
      endSeconds: &endSeconds,
      characterCount: &characterCount
    )
    return Self(version: currentVersion, chunks: chunks)
  }

  private static func canonicalSeconds(_ seconds: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public enum GenerationStepID {
  public static func make(
    jobID: UUID,
    promptVersion: String,
    schemaVersion: String,
    chunkPlanVersion: String,
    kind: GenerationStepKind,
    index: Int,
    inputFingerprint: String
  ) -> String {
    [
      jobID.uuidString,
      promptVersion,
      schemaVersion,
      chunkPlanVersion,
      kind.rawValue,
      String(index),
      inputFingerprint,
    ].joined(separator: "/")
  }

  public static func make(
    job: GenerationJob,
    kind: GenerationStepKind,
    index: Int,
    inputFingerprint: String
  ) -> String {
    make(
      jobID: job.id,
      promptVersion: job.promptVersion,
      schemaVersion: job.schemaVersion,
      chunkPlanVersion: job.chunkPlanVersion,
      kind: kind,
      index: index,
      inputFingerprint: inputFingerprint
    )
  }
}

public enum GenerationInputFingerprint {
  public static func make(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
