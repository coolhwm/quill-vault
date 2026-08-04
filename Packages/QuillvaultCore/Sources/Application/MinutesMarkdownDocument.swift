import Foundation

/// Splits minutes markdown into display blocks, isolating fenced mermaid.
public enum MinutesMarkdownDocument {
  public enum Block: Equatable, Sendable {
    case markdown(String)
    case mermaid(String)
  }

  public static func blocks(from markdown: String) -> [Block] {
    var result: [Block] = []
    var currentMarkdown: [String] = []
    var inMermaid = false
    var mermaidLines: [String] = []

    func flushMarkdown() {
      let text = currentMarkdown.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        result.append(.markdown(text))
      }
      currentMarkdown.removeAll(keepingCapacity: true)
    }

    for line in markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !inMermaid, trimmed.hasPrefix("```") {
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
          .lowercased()
        if language == "mermaid" || language.hasPrefix("mermaid") {
          flushMarkdown()
          inMermaid = true
          mermaidLines = []
          continue
        }
      }
      if inMermaid {
        if trimmed.hasPrefix("```") {
          let source = mermaidLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !source.isEmpty {
            result.append(.mermaid(source))
          }
          inMermaid = false
          mermaidLines = []
        } else {
          mermaidLines.append(line)
        }
        continue
      }
      currentMarkdown.append(line)
    }

    if inMermaid {
      // Unclosed fence: keep source as markdown monospaced body.
      currentMarkdown.append("```mermaid")
      currentMarkdown.append(contentsOf: mermaidLines)
    }
    flushMarkdown()
    return result
  }
}
