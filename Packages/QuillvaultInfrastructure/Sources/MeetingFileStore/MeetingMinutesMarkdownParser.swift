import Domain
import Foundation

struct MeetingMinutesMarkdownParser: Sendable {
  func parse(_ markdown: String) -> MeetingMinutesContent {
    let informationMayBeIncomplete = frontMatterBoolean(
      key: "informationMayBeIncomplete",
      in: markdown
    )
    let withoutFrontMatter = markdown.replacingOccurrences(
      of: #"(?s)^---\r?\n.*?\r?\n---\r?\n"#,
      with: "",
      options: .regularExpression
    )
    let diagramSources = captureAllGroups(
      pattern: #"(?is)```\s*mermaid\s*\n?(.*?)\s*```"#,
      in: withoutFrontMatter
    )
    let summary = withoutFrontMatter.replacingOccurrences(
      of: #"(?is)```\s*mermaid.*?```"#,
      with: "",
      options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    let diagrams = diagramSources.enumerated().map { index, source in
      MeetingDiagram(
        id: "diagram-\(index)",
        title: index == 0 ? nil : "Diagram \(index + 1)",
        source: source.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
    return MeetingMinutesContent(
      summaryMarkdown: summary,
      diagrams: diagrams,
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

  private func captureAllGroups(
    pattern: String,
    in text: String
  ) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1,
        let capture = Range(match.range(at: 1), in: text)
      else {
        return nil
      }
      return String(text[capture])
    }
  }
}
