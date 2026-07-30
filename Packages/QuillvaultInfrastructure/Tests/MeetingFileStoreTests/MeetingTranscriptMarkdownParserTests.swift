import Domain
import Testing

@testable import MeetingFileStore

@Suite("Meeting transcript markdown parser")
struct MeetingTranscriptMarkdownParserTests {
  @Test("Parses stable Chinese and English timestamp anchors")
  func parsesAnchors() throws {
    let markdown = """
      ---
      audioDurationSeconds: 22.4
      ---

      # 文字记录

      - [000.0–015.5] 中文记录
      - [015.5–022.4] English note
      """

    let timeline = try MeetingTranscriptMarkdownParser().parse(markdown)

    #expect(timeline.audioDurationSeconds == 22.4)
    #expect(timeline.segments.map(\.text) == ["中文记录", "English note"])
    #expect(timeline.segments.map(\.startSeconds) == [0, 15.5])
  }

  @Test("Handles a long transcript without losing segments")
  func parsesLongTranscript() throws {
    let segments = (0..<2_000).map { index in
      let start = Double(index)
      return TranscriptAnchorFormatter.line(
        for: TranscriptSegmentCandidate(
          startSeconds: start,
          endSeconds: start + 1,
          text: "segment \(index)"
        )
      )
    }
    let markdown = (["audioDurationSeconds: 2000"] + segments).joined(separator: "\n")

    let timeline = try MeetingTranscriptMarkdownParser().parse(markdown)

    #expect(timeline.segments.count == 2_000)
    #expect(timeline.segments.last?.endSeconds == 2_000)
  }
}
