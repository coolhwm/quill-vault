import Domain
import Foundation
import Testing

@Suite("Transcript timeline")
struct TranscriptTimelineTests {
  @Test("Transcript anchors use readable zero-padded one-decimal seconds")
  func formatsReadableAnchors() {
    let segment = TranscriptSegmentCandidate(
      startSeconds: 0,
      endSeconds: 15.5,
      text: "示例文字记录"
    )

    #expect(
      TranscriptAnchorFormatter.line(for: segment)
        == "- [000.0–015.5] 示例文字记录"
    )
    #expect(TranscriptAnchorFormatter.timestamp(3_600.04) == "3600.0")
    #expect(TranscriptAnchorFormatter.timestamp(.nan) == "000.0")
  }

  @Test("Zero speech results produce an empty timeline")
  func emptyResults() throws {
    let timeline = try TranscriptTimeline.normalizing(
      [],
      audioDurationSeconds: 60
    )

    #expect(timeline.segments.isEmpty)
  }

  @Test("Results are sorted, trimmed, and assigned stable identities")
  func sortsAndNormalizesResults() throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 3, endSeconds: 5, text: "  第二句  "),
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 2, text: "第一句"),
      ],
      audioDurationSeconds: 5
    )

    #expect(timeline.segments.map(\.text) == ["第一句", "第二句"])
    #expect(timeline.segments.map(\.startSeconds) == [0, 3])
    #expect(timeline.segments.map(\.endSeconds) == [2, 5])
    #expect(timeline.segments.allSatisfy { !$0.id.isEmpty })

    let repeated = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 3, endSeconds: 5, text: "第二句"),
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 2, text: "第一句"),
      ],
      audioDurationSeconds: 5
    )
    #expect(repeated.segments.map(\.id) == timeline.segments.map(\.id))
  }

  @Test("Exact duplicate finals are published once")
  func removesDuplicateFinals() throws {
    let candidate = TranscriptSegmentCandidate(
      startSeconds: 1,
      endSeconds: 2,
      text: "不会重复"
    )

    let timeline = try TranscriptTimeline.normalizing(
      [candidate, candidate, candidate],
      audioDurationSeconds: 10
    )

    #expect(timeline.segments.count == 1)
  }

  @Test("Shifted overlapping repeats of the same final text are published once")
  func removesShiftedDuplicateFinals() throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 1, endSeconds: 3, text: "重复内容"),
        TranscriptSegmentCandidate(startSeconds: 1.1, endSeconds: 3.2, text: "重复内容"),
      ],
      audioDurationSeconds: 10
    )

    #expect(timeline.segments.count == 1)
    #expect(timeline.segments.first?.startSeconds == 1)
    #expect(timeline.segments.first?.endSeconds == 3)
  }

  @Test("Overlapping finals are deterministically clipped")
  func clipsOverlap() throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 4, text: "第一段"),
        TranscriptSegmentCandidate(startSeconds: 3, endSeconds: 7, text: "第二段"),
        TranscriptSegmentCandidate(startSeconds: 6, endSeconds: 6.5, text: "被覆盖"),
      ],
      audioDurationSeconds: 10
    )

    #expect(timeline.segments.count == 2)
    #expect(timeline.segments[0].startSeconds == 0)
    #expect(timeline.segments[0].endSeconds == 4)
    #expect(timeline.segments[1].startSeconds == 4)
    #expect(timeline.segments[1].endSeconds == 7)
  }

  @Test("Small recognizer rounding beyond the audio boundary is clamped")
  func clampsToAudioBoundary() throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: -0.01, endSeconds: 10.02, text: "全文")
      ],
      audioDurationSeconds: 10
    )

    #expect(timeline.segments.first?.startSeconds == 0)
    #expect(timeline.segments.first?.endSeconds == 10)
  }

  @Test("Invalid duration and wholly invalid ranges are rejected")
  func rejectsInvalidTimeline() {
    #expect(throws: TranscriptError.invalidAudioDuration) {
      _ = try TranscriptTimeline.normalizing([], audioDurationSeconds: 0)
    }
    #expect(throws: TranscriptError.invalidTimeRange) {
      _ = try TranscriptTimeline.normalizing(
        [TranscriptSegmentCandidate(startSeconds: 8, endSeconds: 7, text: "错误")],
        audioDurationSeconds: 10
      )
    }
  }

  @Test("Revision identity and fingerprint are stable for identical content")
  func stableRevisionIdentity() throws {
    let timeline = try TranscriptTimeline.normalizing(
      [
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 2, text: "你好")
      ],
      audioDurationSeconds: 2
    )

    let first = TranscriptRevision(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "F57D2369-2DC4-462D-9C67-070DA42D310B")!
      ),
      localeIdentifier: "zh-CN",
      timeline: timeline
    )
    let second = TranscriptRevision(
      meetingID: first.meetingID,
      localeIdentifier: "zh-CN",
      timeline: timeline
    )

    #expect(first.id == second.id)
    #expect(first.contentFingerprint == second.contentFingerprint)
  }

  @Test("A three-hour catch-up timeline remains monotonic and bounded")
  func longCatchUpTimeline() throws {
    let duration = 3 * 60 * 60.0
    let candidates = stride(from: 0.0, to: duration, by: 15).flatMap {
      [
        TranscriptSegmentCandidate(
          startSeconds: $0,
          endSeconds: min($0 + 16, duration + 0.2),
          text: "片段 \(Int($0))"
        ),
        TranscriptSegmentCandidate(
          startSeconds: $0,
          endSeconds: min($0 + 16, duration + 0.2),
          text: "片段 \(Int($0))"
        ),
      ]
    }

    let timeline = try TranscriptTimeline.normalizing(
      candidates,
      audioDurationSeconds: duration
    )

    #expect(timeline.segments.count == Int(duration / 15))
    #expect(
      timeline.segments.allSatisfy {
        $0.startSeconds >= 0
          && $0.endSeconds <= duration
          && $0.endSeconds > $0.startSeconds
      })
    #expect(
      zip(timeline.segments, timeline.segments.dropFirst()).allSatisfy {
        $0.endSeconds <= $1.startSeconds
      })
  }
}
