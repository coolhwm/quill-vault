import Foundation

/// Pure transform used when publishing a hand-edited (or model) title into minutes.md.
public enum MinutesTitleRewriter {
  public static func replacingTitle(
    in markdown: String,
    title: String,
    userEdited: Bool
  ) -> String {
    var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    if text.hasPrefix("---") {
      var lines = text.components(separatedBy: "\n")
      var endIndex: Int?
      var titleLine: Int?
      var userEditedLine: Int?
      for (index, line) in lines.enumerated() {
        if index == 0 { continue }
        if line.trimmingCharacters(in: .whitespaces) == "---" {
          endIndex = index
          break
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("title:") {
          titleLine = index
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("titleUserEdited:") {
          userEditedLine = index
        }
      }
      if let endIndex {
        if let titleLine {
          lines[titleLine] = "title: \(title)"
        } else {
          lines.insert("title: \(title)", at: endIndex)
        }
        let editedValue = userEdited ? "true" : "false"
        if let userEditedLine {
          lines[userEditedLine] = "titleUserEdited: \(editedValue)"
        } else {
          let insertAt = (titleLine ?? endIndex) + 1
          lines.insert(
            "titleUserEdited: \(editedValue)",
            at: min(insertAt, endIndex + 1)
          )
        }
        text = lines.joined(separator: "\n")
      }
    }
    var bodyLines = text.components(separatedBy: "\n")
    var replacedH1 = false
    for (index, line) in bodyLines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("# ") || trimmed == "#" {
        bodyLines[index] = "# \(title)"
        replacedH1 = true
        break
      }
      if trimmed.hasPrefix("##") {
        break
      }
    }
    if !replacedH1 {
      if bodyLines.first == "---" {
        if let close = bodyLines.dropFirst().firstIndex(of: "---") {
          let insertAt = bodyLines.index(after: close)
          bodyLines.insert(contentsOf: ["", "# \(title)", ""], at: insertAt)
        }
      } else {
        bodyLines.insert(contentsOf: ["# \(title)", ""], at: 0)
      }
    }
    return bodyLines.joined(separator: "\n")
  }

  public static func title(from markdown: String) -> String? {
    guard let raw = value(named: "title", in: markdown) else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return trimmed.isEmpty ? nil : trimmed
  }

  public static func titleUserEdited(from markdown: String) -> Bool {
    let raw = value(named: "titleUserEdited", in: markdown)?.lowercased()
    return raw == "true" || raw == "1"
  }

  private static func value(named name: String, in text: String) -> String? {
    guard text.hasPrefix("---") else {
      return nil
    }
    let prefix = "\(name):"
    guard
      let line = text.split(separator: "\n").dropFirst().prefix(while: {
        $0.trimmingCharacters(in: .whitespaces) != "---"
      }).first(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
      })
    else {
      return nil
    }
    let value = line.trimmingCharacters(in: .whitespaces)
      .dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : String(value)
  }
}
