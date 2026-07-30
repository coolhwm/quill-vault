import Domain
import Foundation
import Testing

@testable import Application

@Suite("Recording quick start workflow")
struct RecordingQuickStartWorkflowTests {
  private let session = RecordingSession(
    meetingID: MeetingID(
      rawValue: UUID(
        uuidString: "2AF96C33-E782-4CAA-A47C-A39EF37E09C0"
      )!
    ),
    startedAt: Date(timeIntervalSince1970: 1_722_470_400)
  )

  @Test("A ready shortcut starts through the shared recording use case")
  func startsSharedRecordingUseCase() async {
    let recording = QuickStartRecordingUseCaseStub(
      startSnapshot: RecordingSnapshot(
        session: session,
        activity: .recording
      )
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.start()

    #expect(
      outcome
        == .started(
          RecordingSnapshot(session: session, activity: .recording)
        )
    )
    #expect(await recording.restoreCount == 1)
    #expect(await recording.startCount == 1)
  }

  @Test("An interrupted meeting requires a decision before starting")
  func interruptedMeetingRequiresDecision() async {
    let audio = RecordedAudio(
      durationSeconds: 30,
      packetCount: 1_024,
      byteCount: 64_000
    )
    let interrupted = RecordingSnapshot(
      session: session,
      activity: .interrupted(audio)
    )
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshot: interrupted
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.start()

    #expect(outcome == .requiresInterruptedDecision(interrupted))
    #expect(await recording.startCount == 0)
  }

  @Test("An active meeting is never duplicated")
  func activeMeetingIsNotDuplicated() async {
    let active = RecordingSnapshot(
      session: session,
      activity: .recording
    )
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshot: active
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.start()

    #expect(outcome == .alreadyActive(active))
    #expect(await recording.startCount == 0)
  }

  @Test("A competing home start is reported as the active meeting")
  func competingStartRestoresActiveMeeting() async {
    let active = RecordingSnapshot(
      session: session,
      activity: .recording
    )
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshots: [nil, active],
      startError: RecordingError.alreadyRecording
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.start()

    #expect(outcome == .alreadyActive(active))
    #expect(await recording.startCount == 1)
  }

  @Test("Concurrent shortcuts cannot create parallel recordings")
  func concurrentShortcutsAreSerialized() async {
    let started = RecordingSnapshot(
      session: session,
      activity: .recording
    )
    let recording = QuickStartRecordingUseCaseStub(
      startSnapshot: started,
      startDelay: .milliseconds(100)
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    async let first = subject.start()
    while await recording.startCount == 0 {
      await Task.yield()
    }
    let repeated = await subject.start()
    let initial = await first

    #expect(initial == .started(started))
    #expect(repeated == .alreadyStarting)
    #expect(await recording.startCount == 1)
  }

  @Test("A cold-launch shortcut waits for app restoration")
  func shortcutWaitsForColdLaunchRestore() async {
    let started = RecordingSnapshot(
      session: session,
      activity: .recording
    )
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshots: [nil, nil],
      startSnapshot: started,
      restoreDelay: .milliseconds(100)
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    async let restoration = subject.restore()
    while await recording.restoreCount == 0 {
      await Task.yield()
    }
    async let shortcut = subject.start()

    #expect(await restoration == nil)
    #expect(await shortcut == .started(started))
    #expect(await recording.restoreCount == 2)
    #expect(await recording.startCount == 1)
  }

  @Test("Cancelling while cold-launch restore waits never starts audio")
  func cancelledShortcutDoesNotOutliveColdLaunchRestore() async {
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshots: [nil, nil],
      startSnapshot: RecordingSnapshot(
        session: session,
        activity: .recording
      ),
      restoreDelay: .milliseconds(100)
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    async let restoration = subject.restore()
    while await recording.restoreCount == 0 {
      await Task.yield()
    }
    let shortcut = Task {
      await subject.start()
    }
    await Task.yield()
    shortcut.cancel()

    #expect(await shortcut.value == .cancelled)
    #expect(await restoration == nil)
    #expect(await recording.restoreCount == 1)
    #expect(await recording.startCount == 0)
  }

  @Test("Permission and directory failures request app attention")
  func authorizationFailuresRequestAttention() async {
    let microphone = RecordingQuickStartWorkflow(
      recording: QuickStartRecordingUseCaseStub(
        startError: RecordingError.microphonePermissionDenied
      ),
      directory: QuickStartDirectoryUseCaseStub()
    )
    let directory = RecordingQuickStartWorkflow(
      recording: QuickStartRecordingUseCaseStub(
        startError: RecordingError.authoritativeDirectoryUnavailable
      ),
      directory: QuickStartDirectoryUseCaseStub()
    )

    #expect(
      await microphone.start()
        == .requiresAppAttention(.microphonePermission)
    )
    #expect(
      await directory.start()
        == .requiresAppAttention(
          .authoritativeDirectory(.renewAccess)
        )
    )
  }

  @Test("A missing directory requests initial selection before recording")
  func missingDirectoryRequestsSelection() async {
    let recording = QuickStartRecordingUseCaseStub(
      startSnapshot: RecordingSnapshot(
        session: session,
        activity: .recording
      )
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub(restored: nil)
    )

    let outcome = await subject.start()

    #expect(
      outcome
        == .requiresAppAttention(
          .authoritativeDirectory(.chooseDirectory)
        )
    )
    #expect(await recording.restoreCount == 0)
    #expect(await recording.startCount == 0)
  }

  @Test("A stale directory requests reauthorization before recording")
  func staleDirectoryRequestsReauthorization() async {
    let recording = QuickStartRecordingUseCaseStub()
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub(
        restoreError: .bookmarkStale
      )
    )

    let outcome = await subject.start()

    #expect(
      outcome
        == .requiresAppAttention(
          .authoritativeDirectory(.renewAccess)
        )
    )
    #expect(await recording.startCount == 0)
  }

  @Test("Starting fresh preserves an interrupted meeting first")
  func preservesInterruptedMeetingBeforeStartingFresh() async {
    let interrupted = RecordingSnapshot(
      session: session,
      activity: .interrupted(
        RecordedAudio(
          durationSeconds: 45,
          packetCount: 2_000,
          byteCount: 256_000
        )
      )
    )
    let started = RecordingSnapshot(
      session: session,
      activity: .recording
    )
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshot: interrupted,
      startSnapshot: started
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.startNewAfterInterruption()

    #expect(outcome == .started(started))
    #expect(await recording.finishInterruptedCount == 1)
    #expect(await recording.startCount == 1)
  }

  @Test("A failed interrupted save never starts over its audio")
  func failedInterruptedSaveDoesNotStartFresh() async {
    let interrupted = RecordingSnapshot(
      session: session,
      activity: .interrupted(
        RecordedAudio(
          durationSeconds: 45,
          packetCount: 2_000,
          byteCount: 256_000
        )
      )
    )
    let recording = QuickStartRecordingUseCaseStub(
      restoredSnapshot: interrupted,
      finishInterruptedError: .recordingWriteFailed
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.startNewAfterInterruption()

    #expect(outcome == .requiresAppAttention(.retry))
    #expect(await recording.finishInterruptedCount == 1)
    #expect(await recording.startCount == 0)
  }

  @Test("Cancellation is reported without inventing recording success")
  func cancellationIsReported() async {
    let recording = QuickStartRecordingUseCaseStub(
      startError: CancellationError()
    )
    let subject = RecordingQuickStartWorkflow(
      recording: recording,
      directory: QuickStartDirectoryUseCaseStub()
    )

    let outcome = await subject.start()

    #expect(outcome == .cancelled)
  }
}

private struct QuickStartDirectoryUseCaseStub:
  AuthoritativeDirectoryUseCase
{
  let restored: AuthoritativeDirectory?
  let restoreError: DirectoryAccessError?

  init(
    restored: AuthoritativeDirectory? = AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "quick-start-tests"),
      displayName: "Tests",
      kind: .userSelected
    ),
    restoreError: DirectoryAccessError? = nil
  ) {
    self.restored = restored
    self.restoreError = restoreError
  }

  func restore() async throws -> AuthoritativeDirectory? {
    if let restoreError {
      throw restoreError
    }
    return restored
  }

  func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    guard let restored else {
      throw DirectoryAccessError.bookmarkMissing
    }
    return restored
  }
}

private actor QuickStartRecordingUseCaseStub: RecordingUseCase {
  private var restoredSnapshots: [RecordingSnapshot?]
  private let startSnapshot: RecordingSnapshot?
  private let startError: (any Error)?
  private let finishInterruptedError: RecordingError?
  private let startDelay: Duration
  private let restoreDelay: Duration
  private(set) var restoreCount = 0
  private(set) var startCount = 0
  private(set) var finishInterruptedCount = 0

  init(
    restoredSnapshot: RecordingSnapshot? = nil,
    restoredSnapshots: [RecordingSnapshot?]? = nil,
    startSnapshot: RecordingSnapshot? = nil,
    startError: (any Error)? = nil,
    finishInterruptedError: RecordingError? = nil,
    startDelay: Duration = .zero,
    restoreDelay: Duration = .zero
  ) {
    self.restoredSnapshots = restoredSnapshots ?? [restoredSnapshot]
    self.startSnapshot = startSnapshot
    self.startError = startError
    self.finishInterruptedError = finishInterruptedError
    self.startDelay = startDelay
    self.restoreDelay = restoreDelay
  }

  func restore() async throws -> RecordingSnapshot? {
    restoreCount += 1
    if restoreDelay > .zero {
      try await Task.sleep(for: restoreDelay)
    }
    guard !restoredSnapshots.isEmpty else {
      return nil
    }
    return restoredSnapshots.removeFirst()
  }

  func acknowledgeRecordingNotice() async throws {}

  func start() async throws -> RecordingSnapshot {
    startCount += 1
    if startDelay > .zero {
      try await Task.sleep(for: startDelay)
    }
    if let startError {
      throw startError
    }
    guard let startSnapshot else {
      throw RecordingError.captureCouldNotStart
    }
    return startSnapshot
  }

  func catchUpLiveTranscript() async {}

  func stop() async throws -> RecordingCompletion {
    throw RecordingError.noActiveRecording
  }

  func finishInterrupted() async throws -> RecordingCompletion {
    finishInterruptedCount += 1
    if let finishInterruptedError {
      throw finishInterruptedError
    }
    return RecordingCompletion(
      session: RecordingSession(
        meetingID: MeetingID(rawValue: UUID()),
        startedAt: Date(timeIntervalSince1970: 1_722_470_400)
      ),
      audio: RecordedAudio(
        durationSeconds: 45,
        packetCount: 2_000,
        byteCount: 256_000
      )
    )
  }

  func recoverPendingTranscriptions() async throws
    -> [TranscriptionRecoveryResult]
  {
    []
  }
}
