import Domain
import Foundation

struct MeetingMinutesMarkdownParser: Sendable {
  func parse(_ markdown: String) -> MeetingMinutesContent {
    let informationMayBeIncomplete = frontMatterBoolean(
      key: "informationMayBeIncomplete",
      in: markdown
    )
    let diagram = capturedGroup(
      pattern: #"(?s)```mermaid\s*(.*?)\s*```"#,
      in: markdown
    )
    let withoutFrontMatter = markdown.replacingOccurrences(
      of: #"(?s)^---\r?\n.*?\r?\n---\r?\n"#,
      with: "",
      options: .regularExpression
    )
    let summary = withoutFrontMatter.replacingOccurrences(
      of: #"(?s)```mermaid.*?```"#,
      with: "",
      options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return MeetingMinutesContent(
      summaryMarkdown: summary,
      diagramSource: diagram,
      informationMayBeIncomplete: informationMayBeIncomplete
    )
  }

  private func frontMatterBoolean(key: String, in text: String) -> Bool {
    let escapedKey = NSRegularExpression.escapedPattern(for: key)
    let pattern = "(?im)^\\s*\(escapedKey)\\s*:\\s*(true|false)\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return false
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      let valueRange = Range(match.range(at: 1), in: text)
    else {
      return false
    }
    return text[valueRange].lowercased() == "true"
  }

  private func capturedGroup(
    pattern: String,
    in text: String
  ) -> String? {
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: text,
        range: NSRange(text.startIndex..., in: text)
      ),
      let range = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[range])
  }
}
