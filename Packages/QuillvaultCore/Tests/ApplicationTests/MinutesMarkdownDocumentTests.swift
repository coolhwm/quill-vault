import Application
import Testing

@Suite("Minutes markdown document")
struct MinutesMarkdownDocumentTests {
  @Test("Splits mermaid fences without dropping surrounding body")
  func splitsMermaidAndBody() {
    let input = """
      # 主题

      ## 决策
      - 采用方案 A

      ```mermaid
      flowchart TD
        A --> B
      ```

      ## 待办
      - [ ] 跟进
      """
    let blocks = MinutesMarkdownDocument.blocks(from: input)
    #expect(blocks.count == 3)
    guard case .markdown(let head) = blocks[0] else {
      Issue.record("expected leading markdown")
      return
    }
    #expect(head.contains("主题"))
    #expect(head.contains("方案 A"))
    guard case .mermaid(let source) = blocks[1] else {
      Issue.record("expected mermaid")
      return
    }
    #expect(source.contains("flowchart TD"))
    guard case .markdown(let tail) = blocks[2] else {
      Issue.record("expected trailing markdown")
      return
    }
    #expect(tail.contains("待办"))
  }

  @Test("Parses chapter seek timestamps for 妙记-style lines")
  func chapterSeekParsing() {
    let parsed = MinutesMarkdownDocument.chapterSeek(
      from: "[04:40] 原料类商品库存规则"
    )
    #expect(parsed != nil)
    #expect(abs((parsed?.seconds ?? -1) - 280) < 0.001)
    #expect(parsed?.timestamp == "[04:40]")
    #expect(parsed?.title == "原料类商品库存规则")
    #expect(MinutesMarkdownDocument.chapterSeek(from: "普通段落") == nil)
  }

  @Test("Invalid mermaid isolation leaves body markdown intact")
  func keepsBodyWhenOnlyMarkdown() {
    let input = "# Title\n\nBody only."
    let blocks = MinutesMarkdownDocument.blocks(from: input)
    #expect(blocks.count == 1)
    guard case .markdown(let text) = blocks[0] else {
      Issue.record("expected markdown")
      return
    }
    #expect(text.contains("Title"))
    #expect(text.contains("Body only"))
  }
}
