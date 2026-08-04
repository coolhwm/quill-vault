import Foundation
import Testing

@testable import Application

@Suite("Minutes output normalizer")
struct MinutesOutputNormalizerTests {
  @Test("Accepts JSON, fenced JSON, and provider noise")
  func acceptsCompatibleShapes() {
    let response = """
      Here is the requested result:
      ```json
      {"summary":"# 会议结论\\n\\n## 决策\\n保留现有方案。","diagram":"flowchart TD\\n  A[开始] --> B[完成]"}
      ```
      """

    let normalized = MinutesOutputNormalizer.normalize(response)

    #expect(normalized?.markdown.contains("保留现有方案") == true)
    #expect(normalized?.markdown.contains("```mermaid") == true)
    #expect(normalized?.informationMayBeIncomplete == false)
  }

  @Test("Builds a stable flowchart from constrained graph fields")
  func buildsDeterministicGraph() {
    let response = """
      {"summary":"## 决策\\n继续推进。","nodes":[{"id":"b","label":"完成"},{"id":"a","label":"开始"}],"edges":[{"from":"a","to":"b"}]}
      """

    let normalized = MinutesOutputNormalizer.normalize(response)

    #expect(normalized?.markdown.contains("flowchart TD") == true)
    #expect(normalized?.markdown.contains("a[\"开始\"]") == true)
    #expect(normalized?.markdown.contains("a --> b") == true)
  }

  @Test("Publishes readable body when optional structure is missing")
  func missingSecondaryFieldsAreADegradedSuccess() {
    let normalized = MinutesOutputNormalizer.normalize("这是一个可读的会议摘要。")

    #expect(normalized?.markdown == "这是一个可读的会议摘要。")
    #expect(normalized?.informationMayBeIncomplete == true)
  }

  @Test("Invalid Mermaid does not invalidate the text body")
  func invalidDiagramFallsBackToText() {
    let normalized = MinutesOutputNormalizer.normalize(
      """
      # 会议纪要

      ## 决策
      继续推进。

      ```mermaid
      flowchart TD
      A --> <script>alert(1)</script>
      ```
      """)

    #expect(normalized != nil)
    #expect(normalized?.markdown.contains("继续推进") == true)
    #expect(normalized?.markdown.contains("```mermaid") == false)
    #expect(normalized?.informationMayBeIncomplete == true)
  }

  @Test("Normalizes recoverable timestamp ranges")
  func normalizesTimestamps() {
    let normalized = MinutesOutputNormalizer.normalize(
      "## 决策\n[001.0--015.5] 采用新的方案。"
    )

    #expect(normalized?.markdown.contains("[1–15.5]") == true)
    #expect(normalized?.markdown.contains("001.0--015.5") == false)
  }

  @Test("Clamps recoverable ranges to the transcript boundary")
  func clampsTimestampsToTranscript() {
    let normalized = MinutesOutputNormalizer.normalize(
      "## 决策\n[296.3-302.8] 采用新的方案。",
      timelineBounds: 0...300
    )

    #expect(normalized?.markdown.contains("[296.3–300]") == true)
  }

  @Test("Rejects empty, meaningless, and unsafe output")
  func rejectsUnusableOutput() {
    #expect(MinutesOutputNormalizer.normalize("   \n...") == nil)
    #expect(MinutesOutputNormalizer.normalize("<script>alert(1)</script>") == nil)
    #expect(MinutesOutputNormalizer.normalize("javascript:alert(1)") == nil)
    #expect(MinutesOutputNormalizer.normalize("{\"summary\":") == nil)
    #expect(MinutesOutputNormalizer.normalize("{\"error\":\"provider timeout\"}") == nil)
    #expect(MinutesOutputNormalizer.normalize("```json\n{bad}\n```") == nil)
  }

  @Test("Handles a long body without requiring a rigid schema")
  func handlesLongBody() {
    let body = (0..<1_800)
      .map { "## 第\($0 + 1)段\n这是用于长文档展示验证的会议内容。" }
      .joined(separator: "\n\n")

    let normalized = MinutesOutputNormalizer.normalize(body)

    #expect(normalized?.markdown.count == body.count)
  }

  @Test("Preserves multiple safe mermaid diagrams")
  func preservesMultipleDiagrams() {
    let response = """
      # 会议纪要

      ## 总览
      讨论了流程与角色。

      ```mermaid
      flowchart TD
      A[开始] --> B[评审]
      ```

      ```mermaid
      sequenceDiagram
      Alice->>Bob: 确认
      ```
      """

    let normalized = MinutesOutputNormalizer.normalize(response)
    let count =
      normalized?.markdown.components(separatedBy: "```mermaid").count ?? 0
    #expect(count == 3)  // split yields n+1 pieces
    #expect(normalized?.markdown.contains("flowchart TD") == true)
    #expect(normalized?.markdown.contains("sequenceDiagram") == true)
  }

  @Test("Accepts diagrams array from JSON payload")
  func acceptsDiagramsArray() {
    let response = """
      {"summary":"## 决策\\n推进。","diagrams":["flowchart TD\\n  A-->B","flowchart LR\\n  C-->D"]}
      """
    let normalized = MinutesOutputNormalizer.normalize(response)
    #expect(
      normalized?.markdown.contains("A-->B") == true
        || normalized?.markdown.contains("A --> B") == true
        || normalized?.markdown.contains("flowchart") == true)
    let fences =
      normalized?.markdown.components(separatedBy: "```mermaid").count ?? 0
    #expect(fences >= 2)
  }
}
