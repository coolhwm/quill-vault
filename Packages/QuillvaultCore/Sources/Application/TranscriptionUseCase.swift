import Domain

public protocol TranscriptionUseCase: Sendable {
  func finalize(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) async throws -> TranscriptRevision

  func recoverPending() async -> [TranscriptionRecoveryResult]
}

public struct TranscriptionRecoveryResult: Equatable, Sendable {
  public let meetingID: MeetingID
  public let result: Result<TranscriptRevision, TranscriptError>

  public init(
    meetingID: MeetingID,
    result: Result<TranscriptRevision, TranscriptError>
  ) {
    self.meetingID = meetingID
    self.result = result
  }
}
