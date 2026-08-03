import Domain
import Foundation
import Testing

@Suite("Generation chunk plan")
struct GenerationChunkPlanTests {
  @Test("An empty transcript has a stable empty plan")
  func emptyTranscript() throws {
    let revision = try makeRevision(segments: [])

    let first = GenerationChunkPlan.make(from: revision)
    let second = GenerationChunkPlan.make(from: revision)

    #expect(first == second)
    #expect(first.version == "v1")
    #expect(first.chunks.isEmpty)
  }

  @Test("A short transcript stays in one anchored chunk")
  func shortTranscript() throws {
    let revision = try makeRevision(
      segments: [
        TranscriptSegment(
          id: "one",
          startSeconds: 0,
          endSeconds: 4,
          text: "先确认范围"
        ),
        TranscriptSegment(
          id: "two",
          startSeconds: 4,
          endSeconds: 8,
          text: "再安排负责人"
        ),
      ]
    )

    let plan = GenerationChunkPlan.make(from: revision)

    #expect(plan.chunks.count == 1)
    #expect(
      plan.chunks[0].promptText
        == "- [000.0–004.0] 先确认范围\n- [004.0–008.0] 再安排负责人"
    )
    #expect(plan.chunks[0].startSeconds == 0)
    #expect(plan.chunks[0].endSeconds == 8)
    #expect(!plan.chunks[0].inputFingerprint.isEmpty)
  }

  @Test("Long input splits deterministically at transcript boundaries")
  func longTranscript() throws {
    let revision = try makeRevision(
      segments: (0..<5).map { index in
        TranscriptSegment(
          id: "segment-\(index)",
          startSeconds: Double(index * 10),
          endSeconds: Double((index + 1) * 10),
          text: String(repeating: "段\(index)", count: 8)
        )
      }
    )

    let first = GenerationChunkPlan.make(
      from: revision,
      maxCharactersPerChunk: 35,
      maxDurationSeconds: 120
    )
    let second = GenerationChunkPlan.make(
      from: revision,
      maxCharactersPerChunk: 35,
      maxDurationSeconds: 120
    )

    #expect(first == second)
    #expect(first.chunks.count == 5)
    #expect(first.chunks.map(\.index) == Array(0..<5))
    #expect(first.chunks.allSatisfy { !$0.inputFingerprint.isEmpty })
  }

  @Test("Step idempotency keys contain job, versions, kind, index, and input hash")
  func stepIDContainsAllIdentityInputs() throws {
    let revision = try makeRevision(
      segments: [
        TranscriptSegment(
          id: "one",
          startSeconds: 0,
          endSeconds: 2,
          text: "内容"
        )
      ]
    )
    let plan = GenerationChunkPlan.make(from: revision)
    let jobID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let key = GenerationStepID.make(
      jobID: jobID,
      promptVersion: "prompt-2",
      schemaVersion: "schema-3",
      chunkPlanVersion: plan.version,
      kind: .chunkSummary,
      index: 4,
      inputFingerprint: plan.chunks[0].inputFingerprint
    )

    #expect(key.contains(jobID.uuidString))
    #expect(key.contains("prompt-2"))
    #expect(key.contains("schema-3"))
    #expect(key.contains(plan.version))
    #expect(key.contains(GenerationStepKind.chunkSummary.rawValue))
    #expect(key.contains("/4/"))
    #expect(key.hasSuffix(plan.chunks[0].inputFingerprint))
  }
}

private func makeRevision(segments: [TranscriptSegment]) throws -> TranscriptRevision {
  let duration = max(1, segments.map(\.endSeconds).max() ?? 1)
  return TranscriptRevision(
    meetingID: MeetingID(
      rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    ),
    localeIdentifier: "zh-CN",
    timeline: TranscriptTimeline(
      audioDurationSeconds: duration,
      segments: segments
    )
  )
}
