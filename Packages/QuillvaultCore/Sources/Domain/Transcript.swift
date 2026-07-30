import CryptoKit
import Foundation

public enum TranscriptError: Error, Equatable, Sendable {
  case invalidAudioDuration
  case invalidTimeRange
  case unsupportedLocale(String)
  case speechAssetsUnavailable(String)
  case recordingUnavailable
  case recognitionFailed
  case publicationFailed
}

public struct TranscriptSegmentCandidate: Equatable, Sendable {
  public let startSeconds: Double
  public let endSeconds: Double
  public let text: String

  public init(startSeconds: Double, endSeconds: Double, text: String) {
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
    self.text = text
  }
}

public struct TranscriptSegment: Equatable, Codable, Sendable {
  public let id: String
  public let startSeconds: Double
  public let endSeconds: Double
  public let text: String

  public init(
    id: String,
    startSeconds: Double,
    endSeconds: Double,
    text: String
  ) {
    self.id = id
    self.startSeconds = startSeconds
    self.endSeconds = endSeconds
    self.text = text
  }
}

public struct TranscriptTimeline: Equatable, Codable, Sendable {
  public let audioDurationSeconds: Double
  public let segments: [TranscriptSegment]

  public init(
    audioDurationSeconds: Double,
    segments: [TranscriptSegment]
  ) {
    self.audioDurationSeconds = audioDurationSeconds
    self.segments = segments
  }

  public static func normalizing(
    _ candidates: [TranscriptSegmentCandidate],
    audioDurationSeconds: Double
  ) throws -> Self {
    guard audioDurationSeconds.isFinite, audioDurationSeconds > 0 else {
      throw TranscriptError.invalidAudioDuration
    }

    let prepared = try candidates.compactMap { candidate -> PreparedSegment? in
      guard
        candidate.startSeconds.isFinite,
        candidate.endSeconds.isFinite,
        candidate.startSeconds <= candidate.endSeconds
      else {
        throw TranscriptError.invalidTimeRange
      }

      let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        return nil
      }

      let start = min(max(candidate.startSeconds, 0), audioDurationSeconds)
      let end = min(max(candidate.endSeconds, 0), audioDurationSeconds)
      guard end > start else {
        return nil
      }
      return PreparedSegment(startSeconds: start, endSeconds: end, text: text)
    }
    .sorted {
      if $0.startSeconds != $1.startSeconds {
        return $0.startSeconds < $1.startSeconds
      }
      if $0.endSeconds != $1.endSeconds {
        return $0.endSeconds < $1.endSeconds
      }
      return $0.text < $1.text
    }

    var exactFingerprints = Set<String>()
    var normalized: [TranscriptSegment] = []
    for candidate in prepared {
      let exactFingerprint = candidate.fingerprint
      guard exactFingerprints.insert(exactFingerprint).inserted else {
        continue
      }
      if let previous = normalized.last,
        previous.text == candidate.text,
        candidate.startSeconds < previous.endSeconds
      {
        continue
      }

      let start = max(candidate.startSeconds, normalized.last?.endSeconds ?? 0)
      guard candidate.endSeconds > start else {
        continue
      }
      let id = Self.sha256(
        Self.canonical(
          startSeconds: start,
          endSeconds: candidate.endSeconds,
          text: candidate.text
        )
      )
      normalized.append(
        TranscriptSegment(
          id: id,
          startSeconds: start,
          endSeconds: candidate.endSeconds,
          text: candidate.text
        )
      )
    }

    return Self(
      audioDurationSeconds: audioDurationSeconds,
      segments: normalized
    )
  }

  public var canonicalContent: String {
    let lines = segments.map {
      Self.canonical(
        startSeconds: $0.startSeconds,
        endSeconds: $0.endSeconds,
        text: $0.text
      )
    }
    return (["duration=\(Self.canonicalSeconds(audioDurationSeconds))"] + lines)
      .joined(separator: "\n")
  }

  private struct PreparedSegment {
    let startSeconds: Double
    let endSeconds: Double
    let text: String

    var fingerprint: String {
      TranscriptTimeline.sha256(
        TranscriptTimeline.canonical(
          startSeconds: startSeconds,
          endSeconds: endSeconds,
          text: text
        )
      )
    }
  }

  private static func canonical(
    startSeconds: Double,
    endSeconds: Double,
    text: String
  ) -> String {
    "\(canonicalSeconds(startSeconds))|\(canonicalSeconds(endSeconds))|\(text)"
  }

  private static func canonicalSeconds(_ seconds: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
  }

  fileprivate static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public struct TranscriptRevision: Equatable, Codable, Sendable {
  public let id: String
  public let meetingID: MeetingID
  public let localeIdentifier: String
  public let contentFingerprint: String
  public let timeline: TranscriptTimeline

  public init(
    meetingID: MeetingID,
    localeIdentifier: String,
    timeline: TranscriptTimeline
  ) {
    let fingerprint = TranscriptTimeline.sha256(timeline.canonicalContent)
    self.id = TranscriptTimeline.sha256(
      "\(meetingID.rawValue.uuidString.lowercased())|\(localeIdentifier)|\(fingerprint)"
    )
    self.meetingID = meetingID
    self.localeIdentifier = localeIdentifier
    self.contentFingerprint = fingerprint
    self.timeline = timeline
  }
}
