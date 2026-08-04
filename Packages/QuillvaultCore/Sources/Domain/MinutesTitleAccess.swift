import Foundation

public protocol MinutesTitleAccess: Sendable {
  func updateTitle(
    _ title: String,
    userEdited: Bool,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws
}

public enum MinutesTitleAccessError: Error, Equatable, Sendable {
  case minutesUnavailable
  case directoryUnavailable
  case publicationFailed
}
