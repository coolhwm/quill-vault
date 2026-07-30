import Domain
import Foundation

public actor RecordingWorkflow: RecordingUseCase {
  public typealias MeetingIDGenerator = @Sendable () -> MeetingID
  public typealias Clock = @Sendable () -> Date

  private enum Phase {
    case idle
    case checking
    case starting(RecordingSession)
    case recording(RecordingSession)
    case interrupted(RecordingSession, RecordedAudio)
    case finishing(RecordingSession)
  }

  private let capture: any AudioCapture
  private let store: any RecordingSessionStore
  private let consentStore: any RecordingConsentStore
  private let makeMeetingID: MeetingIDGenerator
  private let now: Clock
  private var phase = Phase.idle
  private var interruptedCaptureEvents: [RecordingCaptureEvent] = []

  public init(
    capture: any AudioCapture,
    store: any RecordingSessionStore,
    consentStore: any RecordingConsentStore,
    makeMeetingID: @escaping MeetingIDGenerator,
    now: @escaping Clock
  ) {
    self.capture = capture
    self.store = store
    self.consentStore = consentStore
    self.makeMeetingID = makeMeetingID
    self.now = now
  }

  public func acknowledgeRecordingNotice() async throws {
    do {
      try await consentStore.acknowledgeRecordingNotice()
    } catch {
      throw RecordingError.statePersistenceFailed
    }
  }

  public func restore() async throws -> RecordingSnapshot? {
    switch phase {
    case .idle:
      phase = .checking
      do {
        guard let session = try await store.activeSession() else {
          phase = .idle
          return nil
        }
        let recoveredAudio = try await capture.recoverInterrupted(session)
        if let recoveredAudio, recoveredAudio.isValid {
          interruptedCaptureEvents = try await capture.recordingCaptureEvents(
            meetingID: session.meetingID
          )
          phase = .interrupted(session, recoveredAudio)
          return RecordingSnapshot(
            session: session,
            activity: .interrupted(recoveredAudio),
            captureEvents: interruptedCaptureEvents
          )
        } else {
          interruptedCaptureEvents = []
          try await store.abandon(session)
        }
        phase = .idle
        return nil
      } catch is CancellationError {
        phase = .idle
        throw CancellationError()
      } catch {
        phase = .idle
        throw RecordingError.statePersistenceFailed
      }
    case .recording(let session), .starting(let session):
      return RecordingSnapshot(session: session, activity: .recording)
    case .finishing(let session):
      return RecordingSnapshot(session: session, activity: .finishing)
    case .interrupted(let session, let audio):
      return RecordingSnapshot(
        session: session,
        activity: .interrupted(audio),
        captureEvents: interruptedCaptureEvents
      )
    case .checking:
      throw RecordingError.alreadyRecording
    }
  }

  public func start() async throws -> RecordingSnapshot {
    guard case .idle = phase else {
      throw RecordingError.alreadyRecording
    }
    phase = .checking

    guard await consentStore.hasAcknowledgedRecordingNotice() else {
      phase = .idle
      throw RecordingError.recordingConsentRequired
    }

    do {
      if let existing = try await store.activeSession() {
        phase = .recording(existing)
        throw RecordingError.alreadyRecording
      }
    } catch let error as RecordingError {
      if error != .alreadyRecording {
        phase = .idle
      }
      throw error
    } catch {
      phase = .idle
      throw RecordingError.statePersistenceFailed
    }

    let requestedSession = RecordingSession(
      meetingID: makeMeetingID(),
      startedAt: now()
    )
    phase = .starting(requestedSession)

    let session: RecordingSession
    do {
      let startedAt = try await capture.start(requestedSession)
      try Task.checkCancellation()
      session = RecordingSession(
        meetingID: requestedSession.meetingID,
        startedAt: startedAt
      )
      phase = .starting(session)
    } catch is CancellationError {
      await capture.cancel(meetingID: requestedSession.meetingID)
      phase = .idle
      throw CancellationError()
    } catch {
      await capture.cancel(meetingID: requestedSession.meetingID)
      phase = .idle
      throw mapCaptureError(error)
    }

    do {
      try await store.saveActive(session)
    } catch {
      await capture.cancel(meetingID: session.meetingID)
      phase = .idle
      throw RecordingError.statePersistenceFailed
    }

    phase = .recording(session)
    interruptedCaptureEvents = []
    return RecordingSnapshot(session: session, activity: .recording)
  }

  public func stop() async throws -> RecordingCompletion {
    let session: RecordingSession
    switch phase {
    case .recording(let active), .finishing(let active):
      session = active
    case .idle, .checking, .starting, .interrupted:
      throw RecordingError.noActiveRecording
    }
    phase = .finishing(session)

    let audio: RecordedAudio
    do {
      audio = try await capture.stop(meetingID: session.meetingID)
    } catch RecordingError.invalidRecordedAudio {
      do {
        try await store.abandon(session)
      } catch {
        throw RecordingError.statePersistenceFailed
      }
      phase = .idle
      throw RecordingError.invalidRecordedAudio
    } catch {
      throw mapCaptureError(error)
    }

    guard audio.isValid else {
      do {
        try await store.abandon(session)
      } catch {
        throw RecordingError.statePersistenceFailed
      }
      phase = .idle
      throw RecordingError.invalidRecordedAudio
    }

    do {
      try await store.finish(session, audio: audio)
    } catch {
      throw RecordingError.statePersistenceFailed
    }

    phase = .idle
    interruptedCaptureEvents = []
    return RecordingCompletion(session: session, audio: audio)
  }

  public func finishInterrupted() async throws -> RecordingCompletion {
    guard case .interrupted(let session, let inspectedAudio) = phase else {
      throw RecordingError.noActiveRecording
    }
    phase = .finishing(session)

    let audio: RecordedAudio
    do {
      audio = try await capture.finishInterrupted(session)
    } catch {
      phase = .interrupted(session, inspectedAudio)
      throw mapCaptureError(error)
    }
    guard audio.isValid else {
      phase = .interrupted(session, inspectedAudio)
      throw RecordingError.invalidRecordedAudio
    }

    do {
      try await store.finish(session, audio: audio)
    } catch {
      phase = .interrupted(session, inspectedAudio)
      throw RecordingError.statePersistenceFailed
    }

    phase = .idle
    interruptedCaptureEvents = []
    return RecordingCompletion(session: session, audio: audio)
  }

  public func resumeInterrupted() async throws -> RecordingSnapshot {
    guard case .interrupted(let session, let inspectedAudio) = phase else {
      throw RecordingError.noActiveRecording
    }

    do {
      _ = try await capture.resumeInterrupted(session)
    } catch {
      phase = .interrupted(session, inspectedAudio)
      throw mapCaptureError(error)
    }

    phase = .recording(session)
    interruptedCaptureEvents = []
    return RecordingSnapshot(session: session, activity: .recording)
  }

  public func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    []
  }

  public func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent> {
    await capture.captureEvents(meetingID: meetingID)
  }

  public func catchUpLiveTranscript() async {}

  private func mapCaptureError(_ error: any Error) -> RecordingError {
    return error as? RecordingError ?? .recordingWriteFailed
  }
}
