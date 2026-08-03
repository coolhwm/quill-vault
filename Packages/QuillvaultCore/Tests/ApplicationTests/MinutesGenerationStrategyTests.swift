import Application
import Domain
import Foundation
import Testing

@Suite("Minutes generation strategy")
struct MinutesGenerationStrategyTests {
  @Test("Short transcripts select the brief strategy")
  func shortSelectsBrief() {
    let metrics = MinutesTranscriptMetrics(
      characterCount: 400,
      segmentCount: 6,
      durationSeconds: 180,
      uniqueTextRatio: 0.9
    )
    let strategy = MinutesGenerationStrategySelector.select(metrics: metrics)
    #expect(strategy.id == "brief")
    #expect(strategy.promptVersionToken == "brief@v1")
  }

  @Test("Long dense transcripts select the full strategy")
  func longDenseSelectsFull() {
    let metrics = MinutesTranscriptMetrics(
      characterCount: 9_000,
      segmentCount: 120,
      durationSeconds: 50 * 60,
      uniqueTextRatio: 0.85
    )
    let strategy = MinutesGenerationStrategySelector.select(metrics: metrics)
    #expect(strategy.id == "full")
  }

  @Test("Long but sparse transcripts prefer standard over full")
  func longSparseSelectsStandard() {
    let metrics = MinutesTranscriptMetrics(
      characterCount: 9_000,
      segmentCount: 120,
      durationSeconds: 50 * 60,
      uniqueTextRatio: 0.2
    )
    let strategy = MinutesGenerationStrategySelector.select(metrics: metrics)
    #expect(strategy.id == "standard")
  }

  @Test("Medium transcripts select the standard strategy")
  func mediumSelectsStandard() {
    let metrics = MinutesTranscriptMetrics(
      characterCount: 2_500,
      segmentCount: 40,
      durationSeconds: 20 * 60,
      uniqueTextRatio: 0.7
    )
    let strategy = MinutesGenerationStrategySelector.select(metrics: metrics)
    #expect(strategy.id == "standard")
  }

  @Test("Prompt version tokens resolve back to catalog strategies")
  func promptVersionRoundTrip() {
    for strategy in MinutesGenerationStrategyCatalog.all {
      let resolved = MinutesGenerationStrategyCatalog.strategy(
        forPromptVersionToken: strategy.promptVersionToken
      )
      #expect(resolved.id == strategy.id)
    }
    #expect(
      MinutesGenerationStrategyCatalog.strategy(
        forPromptVersionToken: "unknown@v9"
      ).id == "standard"
    )
  }

  @Test("Title resolver prefers extracted H1 over previous and fallback")
  func titlePrefersExtracted() {
    let title = MinutesTitleResolver.resolve(
      markdown: "# 产品评审结论\n\n会议确认继续推进。",
      previousTitle: "旧标题",
      meetingStartedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(title == "产品评审结论")
  }

  @Test("Banned and empty titles fall back to previous then deterministic title")
  func titleFallbackChain() {
    let previous = MinutesTitleResolver.resolve(
      markdown: "# 会议录音\n\n正文",
      previousTitle: "上一次主题",
      meetingStartedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(previous == "上一次主题")

    let fallback = MinutesTitleResolver.resolve(
      markdown: "没有标题的正文",
      previousTitle: "会议录音",
      meetingStartedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(fallback.hasPrefix("Meeting "))
    #expect(!fallback.contains("会议录音"))
  }

  @Test("Metrics derive from transcript revisions")
  func metricsFromRevision() {
    let revision = TranscriptRevision(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
      ),
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(
        audioDurationSeconds: 120,
        segments: [
          TranscriptSegment(
            id: "1",
            startSeconds: 0,
            endSeconds: 30,
            text: "讨论排期"
          ),
          TranscriptSegment(
            id: "2",
            startSeconds: 30,
            endSeconds: 60,
            text: "确认负责人"
          ),
        ]
      )
    )
    let metrics = MinutesTranscriptMetrics.make(from: revision)
    #expect(metrics.segmentCount == 2)
    #expect(metrics.characterCount == "讨论排期".count + "确认负责人".count)
    #expect(metrics.durationSeconds == 120)
    #expect(metrics.uniqueTextRatio == 1)
  }
}
