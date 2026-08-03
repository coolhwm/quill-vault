import Foundation

public enum MeetingIndexStatus: String, CaseIterable, Codable, Sendable {
  case awaitingTranscript
  case awaitingMinutes
  case minutesCompleted
  case minutesExpired
}

public struct MeetingSearchDocument: Equatable, Sendable {
  public let meetingID: MeetingID
  public let title: String
  public let summary: String
  public let transcript: String

  public init(
    meetingID: MeetingID,
    title: String,
    summary: String,
    transcript: String
  ) {
    self.meetingID = meetingID
    self.title = title
    self.summary = summary
    self.transcript = transcript
  }
}

public struct MeetingSearchQuery: Equatable, Sendable {
  public let text: String
  public let createdFrom: Date?
  public let createdThrough: Date?
  public let statuses: Set<MeetingIndexStatus>
  public let modelName: String?

  public init(
    text: String = "",
    createdFrom: Date? = nil,
    createdThrough: Date? = nil,
    statuses: Set<MeetingIndexStatus> = [],
    modelName: String? = nil
  ) {
    self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    self.createdFrom = createdFrom
    self.createdThrough = createdThrough
    self.statuses = statuses
    self.modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public protocol MeetingSearchCatalog: Sendable {
  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry]
}
