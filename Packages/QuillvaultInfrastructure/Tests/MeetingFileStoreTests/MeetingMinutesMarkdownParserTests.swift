import Testing

@testable import MeetingFileStore

@Suite("Meeting minutes markdown parser")
struct MeetingMinutesMarkdownParserTests {
  @Test("Separates front matter, summary, and Mermaid source")
  func parsesMinutesContent() {
    let markdown = """
      ---
      title: Weekly review
      model: test-model
      informationMayBeIncomplete: true
      ---

      # Weekly review

      A concise summary.

      ```mermaid
      flowchart TD
        A --> B
      ```
      """

    let content = MeetingMinutesMarkdownParser().parse(markdown)

    #expect(content.summaryMarkdown.contains("A concise summary."))
    #expect(!content.summaryMarkdown.contains("title:"))
    #expect(!content.summaryMarkdown.contains("mermaid"))
    #expect(content.diagramSource == "flowchart TD\n  A --> B")
    #expect(content.informationMayBeIncomplete)
  }
}
