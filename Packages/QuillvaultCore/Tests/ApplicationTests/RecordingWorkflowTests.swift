import Application
import Domain
import Foundation
import Testing

@Suite("Recording workflow")
struct RecordingWorkflowTests {
  private let meetingID = MeetingID(
    rawValue: UUID(uuidString: "A992E7B2-B17A-4039-88CC-2770328E8A23")!
  )
  private let startedAt = Date(timeIntervalSince1970: 1_722_470_400)

  @Test("Persists active state only after durable capture starts")
  func startsCaptureBeforeReportingPersistentState() async throws {
    let events = RecordingEvents()
    let capture = AudioCaptureStub(events: events)
    let store = RecordingSessionStoreStub(events: events)
    let workflow = makeWorkflow(capture: capture, store: store)

    let snapshot = try await workflow.start()

    #expect(snapshot.session.meetingID == meetingID)
    #expect(snapshot.activity == .recording)
    #expect(await events.values == [.captureStarted, .stateSaved])
  }

  @Test("Uses the acknowledged capture time instead of preflight request time")
  func usesAcknowledgedCaptureTime() async throws {
    let acknowledgedAt = startedAt.addingTimeInterval(30)
    let capture = AudioCaptureStub(acknowledgedAt: acknowledgedAt)
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(capture: capture, store: store)

    let snapshot = try await workflow.start()

    #expect(snapshot.session.startedAt == acknowledgedAt)
    #expect(await store.savedSessions == [snapshot.session])
  }

  @Test("Recording notice is acknowledged before microphone capture")
  func recordingNoticePrecedesCapture() async throws {
    let consent = RecordingConsentStoreStub(isAcknowledged: false)
    let capture = AudioCaptureStub()
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(
      capture: capture,
      store: store,
      consent: consent
    )

    await #expect(throws: RecordingError.recordingConsentRequired) {
      _ = try await workflow.start()
    }
    #expect(await capture.startCount == 0)

    try await workflow.acknowledgeRecordingNotice()
    _ = try await workflow.start()
    #expect(await capture.startCount == 1)
  }

  @Test("Concurrent starts create only one audio writer")
  func concurrentStartIsSingleOwner() async {
    let capture = AudioCaptureStub(startDelay: .milliseconds(50))
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(capture: capture, store: store)

    await withTaskGroup(of: Result<RecordingSnapshot, RecordingError>.self) { group in
      for _ in 0..<20 {
        group.addTask {
          do {
            return .success(try await workflow.start())
          } catch let error as RecordingError {
            return .failure(error)
          } catch {
            return .failure(.captureCouldNotStart)
          }
        }
      }

      var successCount = 0
      var duplicateCount = 0
      for await result in group {
        switch result {
        case .success:
          successCount += 1
        case .failure(.alreadyRecording):
          duplicateCount += 1
        case .failure:
          Issue.record("Unexpected recording failure")
        }
      }
      #expect(successCount == 1)
      #expect(duplicateCount == 19)
    }
    #expect(await capture.startCount == 1)
  }

  @Test("Permission denial creates no active state or ghost meeting")
  func permissionDenialLeavesNoState() async {
    let capture = AudioCaptureStub(startError: .microphonePermissionDenied)
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(capture: capture, store: store)

    await #expect(throws: RecordingError.microphonePermissionDenied) {
      _ = try await workflow.start()
    }
    #expect(await store.savedSessions.isEmpty)
    #expect(await capture.cancelCount == 1)
  }

  @Test("State write failure cancels only the newly-created capture")
  func stateFailureCancelsCapture() async {
    let capture = AudioCaptureStub()
    let store = RecordingSessionStoreStub(saveError: StoreFailure())
    let workflow = makeWorkflow(capture: capture, store: store)

    await #expect(throws: RecordingError.statePersistenceFailed) {
      _ = try await workflow.start()
    }
    #expect(await capture.cancelCount == 1)
    #expect(await store.savedSessions.isEmpty)
  }

  @Test("Cancellation propagates and cleans the unfinished capture")
  func cancellationPropagates() async {
    let capture = AudioCaptureStub(startDelay: .seconds(5))
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(capture: capture, store: store)
    let task = Task {
      try await workflow.start()
    }

    while await capture.startCount == 0 {
      await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(await capture.cancelCount == 1)
    #expect(await store.savedSessions.isEmpty)
  }

  @Test("A valid stopped recording is persisted before completion")
  func stopPersistsValidatedAudio() async throws {
    let audio = RecordedAudio(
      durationSeconds: 45,
      packetCount: 1_920,
      byteCount: 128_000
    )
    let capture = AudioCaptureStub(stoppedAudio: audio)
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(capture: capture, store: store)
    _ = try await workflow.start()

    let completion = try await workflow.stop()

    #expect(completion.audio == audio)
    #expect(await store.finishedAudio == audio)
  }

  @Test("A zero-duration result never becomes a completed recording")
  func invalidAudioCannotComplete() async throws {
    let capture = AudioCaptureStub(
      stoppedAudio: RecordedAudio(durationSeconds: 0, packetCount: 0, byteCount: 24)
    )
    let store = RecordingSessionStoreStub()
    let workflow = makeWorkflow(capture: capture, store: store)
    _ = try await workflow.start()

    await #expect(throws: RecordingError.invalidRecordedAudio) {
      _ = try await workflow.stop()
    }
    #expect(await store.finishedAudio == nil)
    #expect(await store.abandonedSessions.count == 1)
    _ = try await workflow.start()
    #expect(await capture.startCount == 2)
  }

  @Test("A persisted active session prevents a second meeting")
  func persistedSessionPreventsDuplicate() async {
    let existing = RecordingSession(meetingID: meetingID, startedAt: startedAt)
    let capture = AudioCaptureStub()
    let store = RecordingSessionStoreStub(active: existing)
    let workflow = makeWorkflow(capture: capture, store: store)

    await #expect(throws: RecordingError.alreadyRecording) {
      _ = try await workflow.start()
    }
    #expect(await capture.startCount == 0)
  }

  private func makeWorkflow(
    capture: AudioCaptureStub,
    store: RecordingSessionStoreStub,
    consent: RecordingConsentStoreStub = RecordingConsentStoreStub(
      isAcknowledged: true
    )
  ) -> RecordingWorkflow {
    RecordingWorkflow(
      capture: capture,
      store: store,
      consentStore: consent,
      makeMeetingID: { meetingID },
      now: { startedAt }
    )
  }
}

private enum RecordingEvent: Equatable, Sendable {
  case captureStarted
  case stateSaved
}

private actor RecordingEvents {
  private(set) var values: [RecordingEvent] = []

  func append(_ event: RecordingEvent) {
    values.append(event)
  }
}

private actor AudioCaptureStub: AudioCapture {
  private let events: RecordingEvents?
  private let startDelay: Duration?
  private let startError: RecordingError?
  private let acknowledgedAt: Date?
  private let stoppedAudio: RecordedAudio

  private(set) var startCount = 0
  private(set) var cancelCount = 0

  init(
    events: RecordingEvents? = nil,
    startDelay: Duration? = nil,
    startError: RecordingError? = nil,
    acknowledgedAt: Date? = nil,
    stoppedAudio: RecordedAudio = RecordedAudio(
      durationSeconds: 1,
      packetCount: 1,
      byteCount: 1
    )
  ) {
    self.events = events
    self.startDelay = startDelay
    self.startError = startError
    self.acknowledgedAt = acknowledgedAt
    self.stoppedAudio = stoppedAudio
  }

  func start(_ session: RecordingSession) async throws -> Date {
    startCount += 1
    if let startDelay {
      try await Task.sleep(for: startDelay)
    }
    if let startError {
      throw startError
    }
    await events?.append(.captureStarted)
    return acknowledgedAt ?? session.startedAt
  }

  func stop(meetingID: MeetingID) async throws -> RecordedAudio {
    stoppedAudio
  }

  func cancel(meetingID: MeetingID) async {
    cancelCount += 1
  }
}

private actor RecordingSessionStoreStub: RecordingSessionStore {
  private let events: RecordingEvents?
  private let saveError: (any Error & Sendable)?
  private var active: RecordingSession?

  private(set) var savedSessions: [RecordingSession] = []
  private(set) var finishedAudio: RecordedAudio?
  private(set) var abandonedSessions: [RecordingSession] = []

  init(
    events: RecordingEvents? = nil,
    saveError: (any Error & Sendable)? = nil,
    active: RecordingSession? = nil
  ) {
    self.events = events
    self.saveError = saveError
    self.active = active
  }

  func activeSession() async throws -> RecordingSession? {
    active
  }

  func saveActive(_ session: RecordingSession) async throws {
    if let saveError {
      throw saveError
    }
    savedSessions.append(session)
    active = session
    await events?.append(.stateSaved)
  }

  func finish(
    _ session: RecordingSession,
    audio: RecordedAudio
  ) async throws {
    finishedAudio = audio
    active = nil
  }

  func abandon(_ session: RecordingSession) async throws {
    abandonedSessions.append(session)
    active = nil
  }
}

private struct StoreFailure: Error, Sendable {}

private actor RecordingConsentStoreStub: RecordingConsentStore {
  private var isAcknowledged: Bool

  init(isAcknowledged: Bool) {
    self.isAcknowledged = isAcknowledged
  }

  func hasAcknowledgedRecordingNotice() async -> Bool {
    isAcknowledged
  }

  func acknowledgeRecordingNotice() async throws {
    isAcknowledged = true
  }
}
