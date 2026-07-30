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
  public let transcriptRevision: TranscriptRevision?

  public init(
    session: RecordingSession,
    audio: RecordedAudio,
    transcriptRevision: TranscriptRevision? = nil
  ) {
    self.session = session
    self.audio = audio
    self.transcriptRevision = transcriptRevision
  }
}

public struct LiveTranscriptSnapshot: Equatable, Sendable {
  public let finalSegments: [TranscriptSegmentCandidate]
  public let volatileSegment: TranscriptSegmentCandidate?

  public init(
    finalSegments: [TranscriptSegmentCandidate] = [],
    volatileSegment: TranscriptSegmentCandidate? = nil
  ) {
    self.finalSegments = finalSegments
    self.volatileSegment = volatileSegment
  }

  public var displayText: String {
    (finalSegments.map(\.text) + [volatileSegment?.text].compactMap { $0 })
      .joined(separator: "\n")
  }
}

public protocol TranscriptionRecoveryUseCase: Sendable {
  func recoverPendingTranscriptions() async throws -> [TranscriptionRecoveryResult]
}

public protocol RecordingUseCase: TranscriptionRecoveryUseCase {
  func restore() async throws -> RecordingSnapshot?
  func acknowledgeRecordingNotice() async throws
  func start() async throws -> RecordingSnapshot
  func liveTranscript(
    meetingID: MeetingID
  ) async -> AsyncStream<LiveTranscriptSnapshot>
  func stop() async throws -> RecordingCompletion
}

extension RecordingUseCase {
  public func liveTranscript(
    meetingID: MeetingID
  ) async -> AsyncStream<LiveTranscriptSnapshot> {
    AsyncStream { $0.finish() }
  }
}
