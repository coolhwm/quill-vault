import Domain
import Foundation
import Testing

@Suite("Generation primary transcript")
struct GenerationPrimaryTranscriptTests {
  @Test("Prefers optimized when present for expiry comparison")
  func prefersOptimized() throws {
    let meetingID = MeetingID(rawValue: UUID())
    let originalTimeline = try TranscriptTimeline.normalizing(
      [TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "原文")],
      audioDurationSeconds: 1
    )
    let optimizedTimeline = try TranscriptTimeline.normalizing(
      [TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "优化")],
      audioDurationSeconds: 1
    )
    let original = GenerationPrimaryTranscript.candidate(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: originalTimeline,
      kind: .original
    )
    let optimized = GenerationPrimaryTranscript.candidate(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: optimizedTimeline,
      kind: .optimized
    )
    let primary = GenerationPrimaryTranscript.prefer(
      original: original,
      optimized: optimized
    )
    #expect(primary?.kind == .optimized)
    #expect(primary?.contentFingerprint == optimized.contentFingerprint)
    #expect(primary?.contentFingerprint != original.contentFingerprint)

    let entry = MeetingIndexEntry(
      id: meetingID,
      createdAt: Date(timeIntervalSince1970: 1),
      relativeDirectory: "meeting-test",
      assets: [.transcript, .minutes],
      transcriptRevisionID: primary?.revisionID,
      transcriptFingerprint: primary?.contentFingerprint,
      minutesTranscriptRevisionID: optimized.revisionID,
      minutesTranscriptFingerprint: optimized.contentFingerprint
    )
    #expect(entry.status == .minutesCompleted)
  }

  @Test("Falls back to original when optimized missing")
  func fallsBackToOriginal() throws {
    let meetingID = MeetingID(rawValue: UUID())
    let originalTimeline = try TranscriptTimeline.normalizing(
      [TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "原文")],
      audioDurationSeconds: 1
    )
    let original = GenerationPrimaryTranscript.candidate(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: originalTimeline,
      kind: .original
    )
    let primary = GenerationPrimaryTranscript.prefer(
      original: original,
      optimized: nil
    )
    #expect(primary?.kind == .original)
    #expect(primary?.contentFingerprint == original.contentFingerprint)
  }
}
