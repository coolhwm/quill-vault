import Foundation

public protocol AudioCapture: Sendable {
  func start(_ session: RecordingSession) async throws -> Date
  func liveFrames(meetingID: MeetingID) async -> AsyncStream<AudioFrame>
  func stop(meetingID: MeetingID) async throws -> RecordedAudio
  func recoverInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio?
  func cancel(meetingID: MeetingID) async
}

extension AudioCapture {
  public func liveFrames(meetingID: MeetingID) async -> AsyncStream<AudioFrame> {
    AsyncStream { $0.finish() }
  }

  public func recoverInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio? {
    nil
  }
}
