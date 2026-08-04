import Foundation

/// Line-level presentation tokens for minutes Markdown (Presentation consumes these).
public enum MinutesMarkdownLine: Equatable, Sendable {
  case blank
  case heading(level: Int, text: String)
  case quote(String)
  case task(done: Bool, text: String)
  case bullet(String)
  case ordered(index: Int, text: String)
  case chapterSeek(seconds: Double, timestamp: String, title: String)
  case code(String)
  case table(rows: [[String]])
  case paragraph(String)
}

public enum MinutesMarkdownLineParser {
  /// Parses a markdown body (no mermaid fences) into display lines, including
  /// fenced non-mermaid code blocks and GFM pipe tables.
  public static func lines(from markdown: String) -> [MinutesMarkdownLine] {
    let raw = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var result: [MinutesMarkdownLine] = []
    var index = 0
    while index < raw.count {
      let line = raw[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        result.append(.blank)
        index += 1
        continue
      }

      if trimmed.hasPrefix("```") {
        var code: [String] = []
        index += 1
        while index < raw.count {
          let codeLine = raw[index]
          if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            index += 1
            break
          }
          code.append(codeLine)
          index += 1
        }
        result.append(.code(code.joined(separator: "\n")))
        continue
      }

      if isTableRow(trimmed), index + 1 < raw.count, isTableSeparator(raw[index + 1]) {
        var rows: [[String]] = [splitTableCells(trimmed)]
        index += 2  // skip header + separator
        while index < raw.count {
          let next = raw[index].trimmingCharacters(in: .whitespaces)
          if !isTableRow(next) { break }
          rows.append(splitTableCells(next))
          index += 1
        }
        result.append(.table(rows: rows))
        continue
      }

      if trimmed.hasPrefix("### ") {
        result.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
      } else if trimmed.hasPrefix("## ") {
        result.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
      } else if trimmed.hasPrefix("# ") {
        result.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
      } else if trimmed.hasPrefix("> ") {
        result.append(.quote(String(trimmed.dropFirst(2))))
      } else if trimmed.hasPrefix("- [ ] ") {
        result.append(.task(done: false, text: String(trimmed.dropFirst(6))))
      } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
        result.append(.task(done: true, text: String(trimmed.dropFirst(6))))
      } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        result.append(.bullet(String(trimmed.dropFirst(2))))
      } else if let ordered = orderedListLine(trimmed) {
        result.append(.ordered(index: ordered.index, text: ordered.text))
      } else if let seek = MinutesMarkdownDocument.chapterSeek(from: trimmed) {
        result.append(
          .chapterSeek(
            seconds: seek.seconds,
            timestamp: seek.timestamp,
            title: seek.title
          )
        )
      } else {
        result.append(.paragraph(line))
      }
      index += 1
    }
    return result
  }

  private static func orderedListLine(_ trimmed: String) -> (index: Int, text: String)? {
    guard let dot = trimmed.firstIndex(of: ".") else { return nil }
    let number = trimmed[..<dot]
    guard let value = Int(number), value > 0 else { return nil }
    let rest = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    guard !rest.isEmpty else { return nil }
    return (value, rest)
  }

  private static func isTableRow(_ trimmed: String) -> Bool {
    trimmed.contains("|") && !isTableSeparator(trimmed)
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|"), trimmed.contains("-") else { return false }
    let body = trimmed.replacingOccurrences(of: "|", with: "")
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")
    return body.isEmpty
  }

  private static func splitTableCells(_ row: String) -> [String] {
    var cells = row.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    if cells.first == "" { cells.removeFirst() }
    if cells.last == "" { cells.removeLast() }
    return cells
  }
}
