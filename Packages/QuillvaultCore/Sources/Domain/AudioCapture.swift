import Foundation

public struct ActiveRecordingAudioSegment: Equatable, Sendable {
  public let fileURL: URL
  public let timelineOffsetSeconds: Double

  public init(fileURL: URL, timelineOffsetSeconds: Double) {
    self.fileURL = fileURL
    self.timelineOffsetSeconds = timelineOffsetSeconds
  }
}

public protocol AudioCapture: Sendable {
  func start(_ session: RecordingSession) async throws -> Date
  func liveFrames(meetingID: MeetingID) async -> AsyncStream<AudioFrame>
  func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent>
  func recordingCaptureEvents(
    meetingID: MeetingID
  ) async throws -> [RecordingCaptureEvent]
  func activeRecordingAudioSegments(
    meetingID: MeetingID
  ) async -> [ActiveRecordingAudioSegment]
  func stop(meetingID: MeetingID) async throws -> RecordedAudio
  func recoverInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio?
  func resumeInterrupted(_ session: RecordingSession) async throws -> Date
  func finishInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio
  func cancel(meetingID: MeetingID) async
}

extension AudioCapture {
  public func liveFrames(meetingID: MeetingID) async -> AsyncStream<AudioFrame> {
    AsyncStream { $0.finish() }
  }

  public func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent> {
    AsyncStream { $0.finish() }
  }

  public func activeRecordingAudioSegments(
    meetingID: MeetingID
  ) async -> [ActiveRecordingAudioSegment] {
    []
  }

  public func recoverInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio? {
    nil
  }

  public func finishInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio {
    throw RecordingError.noActiveRecording
  }

  public func resumeInterrupted(
    _ session: RecordingSession
  ) async throws -> Date {
    throw RecordingError.noActiveRecording
  }
}
