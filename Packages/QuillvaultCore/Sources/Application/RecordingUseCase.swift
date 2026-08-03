import Domain

public enum RecordingActivity: Equatable, Sendable {
  case recording
  case finishing
  case interrupted(RecordedAudio)
}

public struct RecordingSnapshot: Equatable, Sendable {
  public let session: RecordingSession
  public let activity: RecordingActivity
  public let captureEvents: [RecordingCaptureEvent]

  public init(
    session: RecordingSession,
    activity: RecordingActivity,
    captureEvents: [RecordingCaptureEvent] = []
  ) {
    self.session = session
    self.activity = activity
    self.captureEvents = captureEvents
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
    (finalSegments.map(TranscriptAnchorFormatter.line)
      + [volatileSegment].compactMap { $0 }.map(TranscriptAnchorFormatter.line))
      .joined(separator: "\n")
  }

  /// Stable identity for the latest projected line, used by the recording UI
  /// to pin auto-scroll to the newest content without depending on layout.
  public var latestLineID: String {
    if let volatileSegment {
      return "volatile:\(TranscriptAnchorFormatter.line(for: volatileSegment))"
    }
    if let last = finalSegments.last {
      return "final:\(TranscriptAnchorFormatter.line(for: last))"
    }
    return "empty"
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
  func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent>
  func catchUpLiveTranscript() async
  func stop() async throws -> RecordingCompletion
  func resumeInterrupted() async throws -> RecordingSnapshot
  func finishInterrupted() async throws -> RecordingCompletion
}

extension RecordingUseCase {
  public func liveTranscript(
    meetingID: MeetingID
  ) async -> AsyncStream<LiveTranscriptSnapshot> {
    AsyncStream { $0.finish() }
  }

  public func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent> {
    AsyncStream { $0.finish() }
  }

  public func finishInterrupted() async throws -> RecordingCompletion {
    throw RecordingError.noActiveRecording
  }

  public func resumeInterrupted() async throws -> RecordingSnapshot {
    throw RecordingError.noActiveRecording
  }
}
