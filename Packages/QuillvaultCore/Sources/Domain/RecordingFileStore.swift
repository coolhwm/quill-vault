import Foundation

public struct RecordingFileReservation: Equatable, Sendable {
  public let meetingID: MeetingID
  public let createdAt: Date
  public let directoryURL: URL
  public let recordingURL: URL

  public init(
    meetingID: MeetingID,
    createdAt: Date,
    directoryURL: URL,
    recordingURL: URL
  ) {
    self.meetingID = meetingID
    self.createdAt = createdAt
    self.directoryURL = directoryURL
    self.recordingURL = recordingURL
  }
}

public protocol RecordingFileStore: Sendable {
  func reserveRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation
  func publishRecordingStart(
    _ reservation: RecordingFileReservation,
    startedAt: Date
  ) async throws
  func recoverInterruptedRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation?
  func finishRecording(meetingID: MeetingID) async throws
  func abandonRecording(meetingID: MeetingID) async
  func cancelRecording(meetingID: MeetingID) async
}

extension RecordingFileStore {
  public func recoverInterruptedRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation? {
    nil
  }
}
