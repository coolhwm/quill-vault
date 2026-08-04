import Domain
import Foundation

extension MeetingFileStore: MinutesTitleAccess {
  public func updateTitle(
    _ title: String,
    userEdited: Bool,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws {
    let sanitized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty else {
      throw MinutesTitleAccessError.publicationFailed
    }
    do {
      try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        let minutesURL = meetingURL.appending(path: "minutes.md")
        guard FileManager.default.fileExists(atPath: minutesURL.path) else {
          throw MinutesTitleAccessError.minutesUnavailable
        }
        let original = try coordinatedReadString(at: minutesURL)
        let updated = Self.replacingTitle(
          in: original,
          title: sanitized,
          userEdited: userEdited
        )
        let candidateURL = meetingURL.appending(
          path: ".minutes-title-\(dependencies.makeUUID().uuidString).tmp"
        )
        let data = Data(updated.utf8)
        try dependencies.fileMutator.writeSynced(data, to: candidateURL)
        if FileManager.default.fileExists(atPath: minutesURL.path) {
          try dependencies.fileMutator.replace(
            itemAt: minutesURL,
            with: candidateURL,
            backupItemName: nil,
            keepBackup: false
          )
        } else {
          try dependencies.fileMutator.move(itemAt: candidateURL, to: minutesURL)
        }
        guard try coordinatedReadString(at: minutesURL) == updated else {
          throw MinutesTitleAccessError.publicationFailed
        }
      }
    } catch let error as MinutesTitleAccessError {
      throw error
    } catch {
      throw MinutesTitleAccessError.publicationFailed
    }
  }

  static func replacingTitle(
    in markdown: String,
    title: String,
    userEdited: Bool
  ) -> String {
    var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    // Front matter title field
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
          lines.insert("titleUserEdited: \(editedValue)", at: min(insertAt, endIndex + 1))
        }
        text = lines.joined(separator: "\n")
      }
    }
    // First H1 in body
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
      // Insert after front matter
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
}
