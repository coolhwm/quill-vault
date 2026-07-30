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

public struct RecordingContinuationReservation: Equatable, Sendable {
  public let meetingID: MeetingID
  public let originalRecordingURL: URL
  public let continuationURL: URL
  public let candidateURL: URL

  public init(
    meetingID: MeetingID,
    originalRecordingURL: URL,
    continuationURL: URL,
    candidateURL: URL
  ) {
    self.meetingID = meetingID
    self.originalRecordingURL = originalRecordingURL
    self.continuationURL = continuationURL
    self.candidateURL = candidateURL
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
  func recordCaptureEvent(
    _ event: RecordingCaptureEvent,
    meetingID: MeetingID
  ) async throws
  func recordingCaptureEvents(
    meetingID: MeetingID
  ) async throws -> [RecordingCaptureEvent]
  func reserveRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation
  func recoverRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation?
  func commitRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async throws
  func cancelRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async
  func quarantineRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async
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

  public func recordCaptureEvent(
    _ event: RecordingCaptureEvent,
    meetingID: MeetingID
  ) async throws {}

  public func reserveRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation {
    throw RecordingError.recordingWriteFailed
  }

  public func recoverRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation? {
    nil
  }

  public func commitRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async throws {
    throw RecordingError.recordingWriteFailed
  }

  public func cancelRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async {}

  public func quarantineRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async {}
}
