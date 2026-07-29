import Domain

public enum RecordingActivity: Equatable, Sendable {
  case recording
  case finishing
}

public struct RecordingSnapshot: Equatable, Sendable {
  public let session: RecordingSession
  public let activity: RecordingActivity

  public init(session: RecordingSession, activity: RecordingActivity) {
    self.session = session
    self.activity = activity
  }
}

public struct RecordingCompletion: Equatable, Sendable {
  public let session: RecordingSession
  public let audio: RecordedAudio

  public init(session: RecordingSession, audio: RecordedAudio) {
    self.session = session
    self.audio = audio
  }
}

public protocol RecordingUseCase: Sendable {
  func restore() async throws -> RecordingSnapshot?
  func acknowledgeRecordingNotice() async throws
  func start() async throws -> RecordingSnapshot
  func stop() async throws -> RecordingCompletion
}
