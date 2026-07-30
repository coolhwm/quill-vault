import Domain
import Foundation

struct MeetingTranscriptMarkdownParser: Sendable {
  func parse(_ markdown: String) throws -> TranscriptTimeline {
    let lines = markdown.split(
      separator: "\n",
      omittingEmptySubsequences: false
    )
    let declaredDuration = Self.audioDuration(from: markdown)

    let candidates = lines.compactMap(parseSegment)
    let lastEnd = candidates.map(\.endSeconds).max() ?? 0
    let duration = max(declaredDuration ?? 0, lastEnd)
    guard duration > 0 else {
      throw TranscriptError.invalidAudioDuration
    }
    return try TranscriptTimeline.normalizing(
      candidates,
      audioDurationSeconds: duration
    )
  }

  static func audioDuration(from markdown: String) -> Double? {
    markdown.split(separator: "\n")
      .first { $0.hasPrefix("audioDurationSeconds:") }
      .flatMap {
        Double(
          $0.dropFirst("audioDurationSeconds:".count)
            .trimmingCharacters(in: .whitespaces)
        )
      }
  }

  private func parseSegment(_ line: Substring) -> TranscriptSegmentCandidate? {
    guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else {
      return nil
    }
    let rangeStart = line.index(line.startIndex, offsetBy: 3)
    let range = line[rangeStart..<close]
    let bounds = range.split(separator: "–", maxSplits: 1)
    guard
      bounds.count == 2,
      let start = Double(bounds[0]),
      let end = Double(bounds[1])
    else {
      return nil
    }
    let textStart = line.index(after: close)
    let text = line[textStart...].trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
      return nil
    }
    return TranscriptSegmentCandidate(
      startSeconds: start,
      endSeconds: end,
      text: text
    )
  }
}
