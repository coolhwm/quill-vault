@testable import Application
import Domain
import Foundation
import Testing

@Suite("Hand-edited minutes title preservation")
struct MinutesTitlePreserveIntegrationTests {
  @Test("Builder preserves hand-edited minutes title over stale index title")
  func builderUsesMinutesTitleNotStaleIndex() throws {
    let originalMinutes = """
      ---
      schemaVersion: 1
      title: "旧索引标题"
      generationJobID: 11111111-1111-1111-1111-111111111111
      generationNumber: 1
      transcriptRevisionID: rev-1
      transcriptFingerprint: fp-1
      model: test-model
      informationMayBeIncomplete: false
      ---

      # 旧索引标题

      ## 决策
      保留方案。
      """

    // Drive the shipped rewriter (same path as MeetingFileStore.updateTitle).
    let handEdited = MinutesTitleRewriter.replacingTitle(
      in: originalMinutes,
      title: "用户手改标题",
      userEdited: true
    )
    #expect(MinutesTitleRewriter.title(from: handEdited) == "用户手改标题")
    #expect(MinutesTitleRewriter.titleUserEdited(from: handEdited))
    #expect(handEdited.contains("# 用户手改标题"))

    // Same fields GenerationFileStore.loadMinutesSnapshot exposes.
    let snapshot = GenerationMinutesSnapshot(
      contentFingerprint: "fp",
      generationJobID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
      transcriptRevisionID: "rev-1",
      transcriptFingerprint: "fp-1",
      title: MinutesTitleRewriter.title(from: handEdited),
      titleUserEdited: MinutesTitleRewriter.titleUserEdited(from: handEdited)
    )
    #expect(snapshot.title == "用户手改标题")
    #expect(snapshot.titleUserEdited)

    let meetingID = MeetingID(
      rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    let staleMeeting = MeetingIndexEntry(
      id: meetingID,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: "meeting-test",
      assets: [.transcript, .minutes],
      title: "旧索引标题",
      transcriptRevisionID: "rev-1",
      transcriptFingerprint: "fp-1"
    )
    let transcript = TranscriptRevision(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: try TranscriptTimeline.normalizing(
        [
          TranscriptSegmentCandidate(
            startSeconds: 0,
            endSeconds: 1,
            text: "讨论方案"
          )
        ],
        audioDurationSeconds: 1
      )
    )
    let job = GenerationJob(
      id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      meetingID: meetingID,
      transcriptRevisionID: transcript.id,
      transcriptFingerprint: transcript.contentFingerprint,
      modelProfile: ModelProfileSnapshot(
        profileID: ModelProfileID(rawValue: UUID()),
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "test",
        parameters: ModelGenerationParameters(),
        credentialReference: ModelCredentialReference(rawValue: UUID())
      ),
      createdAt: Date(timeIntervalSince1970: 1_800_000_100),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
      state: .running,
      stage: .publishing,
      progress: 90
    )

    // Same selection GenerationWorkflow performs before publish.
    let previousTitle = snapshot.title ?? staleMeeting.title
    let built = MinutesDocumentBuilder.build(
      output: "# 模型新标题\n\n## 决策\n新模型正文",
      job: job,
      transcript: transcript,
      meeting: staleMeeting,
      informationMayBeIncomplete: false,
      previousTitle: previousTitle,
      preserveUserTitle: snapshot.titleUserEdited
    )

    #expect(built.contains("title: \"用户手改标题\""))
    #expect(built.contains("titleUserEdited: true"))
    #expect(built.contains("# 用户手改标题"))
    #expect(!built.contains("旧索引标题"))
    #expect(!built.contains("模型新标题"))
  }
}
