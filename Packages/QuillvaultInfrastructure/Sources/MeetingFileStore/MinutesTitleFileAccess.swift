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
        let updated = MinutesTitleRewriter.replacingTitle(
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

}
