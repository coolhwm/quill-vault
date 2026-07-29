import Foundation

public struct RecordingSession: Equatable, Sendable {
  public let meetingID: MeetingID
  public let startedAt: Date

  public init(meetingID: MeetingID, startedAt: Date) {
    self.meetingID = meetingID
    self.startedAt = startedAt
  }
}
