import Foundation

public protocol AudioCapture: Sendable {
  func start(_ session: RecordingSession) async throws -> Date
  func stop(meetingID: MeetingID) async throws -> RecordedAudio
  func cancel(meetingID: MeetingID) async
}
