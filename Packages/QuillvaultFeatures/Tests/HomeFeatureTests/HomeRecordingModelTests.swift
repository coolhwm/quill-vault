import Application
import Domain
import Foundation
import Testing

@testable import HomeFeature

@MainActor
@Suite("Home recording model")
struct HomeRecordingModelTests {
  @Test("Successful start presents the recording session")
  func startPresentsSession() async {
    let useCase = RecordingUseCaseStub()
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()

    #expect(model.state == .recording(.fixture()))
    #expect(model.isSessionPresented)
  }

  @Test("First recording presents notice before retrying start")
  func noticeIsAcknowledged() async {
    let useCase = RecordingUseCaseStub(startErrors: [.recordingConsentRequired])
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    #expect(model.isRecordingNoticePresented)

    await model.acknowledgeNoticeAndStart()
    #expect(await useCase.acknowledgementCount == 1)
    #expect(model.state == .recording(.fixture()))
  }

  @Test("Stop failure keeps the focused screen available for retry")
  func stopFailureCanRetry() async {
    let useCase = RecordingUseCaseStub(stopError: .recordingWriteFailed)
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    await model.stop()

    #expect(
      model.state == .finishFailed(.fixture(), .recordingWriteFailed)
    )
    #expect(model.isSessionPresented)
  }

  @Test("Saved audio exits recording and can recover its pending transcript")
  func pendingTranscriptCanRecover() async {
    let revision = TranscriptRevision(
      meetingID: RecordingSession.fixture().meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(audioDurationSeconds: 60, segments: [])
    )
    let useCase = RecordingUseCaseStub(
      recoveryResults: [
        TranscriptionRecoveryResult(
          meetingID: revision.meetingID,
          result: .success(revision)
        )
      ]
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    await model.stop()

    #expect(!model.isSessionPresented)
    guard case .completed(let pending) = model.state else {
      Issue.record("Expected saved recording completion")
      return
    }
    #expect(pending.transcriptRevision == nil)

    await model.retryTranscript()

    guard case .completed(let recovered) = model.state else {
      Issue.record("Expected recovered recording completion")
      return
    }
    #expect(recovered.transcriptRevision == revision)
    #expect(model.transcriptRecoveryState == .idle)
    #expect(await useCase.recoveryCount == 1)
  }

  @Test("Repeated stop taps stop the audio only once")
  func repeatedStopIsIdempotent() async {
    let useCase = RecordingUseCaseStub(stopDelay: .milliseconds(100))
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    let firstStop = Task {
      await model.stop()
    }
    while model.state != .finishing(.fixture()) {
      await Task.yield()
    }
    await model.stop()
    await firstStop.value

    #expect(await useCase.stopCount == 1)
    #expect(!model.isSessionPresented)
  }

  @Test("Invalid audio exits the recording screen without claiming success")
  func invalidAudioExitsFocusedScreen() async {
    let useCase = RecordingUseCaseStub(stopError: .invalidRecordedAudio)
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    await model.stop()

    #expect(model.state == .startFailed(.invalidRecordedAudio))
    #expect(!model.isSessionPresented)
  }

  @Test("An interrupted meeting offers ending and transcript recovery")
  func interruptedMeetingCanEnd() async {
    let audio = RecordedAudio(
      durationSeconds: 45,
      packetCount: 2_000,
      byteCount: 256_000
    )
    let interruptedAt = RecordingSession.fixture().startedAt
      .addingTimeInterval(40)
    let useCase = RecordingUseCaseStub(
      restoredSnapshot: RecordingSnapshot(
        session: .fixture(),
        activity: .interrupted(audio),
        captureEvents: [
          .interruptionBegan(
            at: interruptedAt,
            reason: .processTermination
          )
        ]
      )
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.restore()
    #expect(model.state == .interrupted(.fixture(), audio))
    #expect(
      model.interruptionGaps == [
        RecordingInterruptionGap(
          startedAt: interruptedAt,
          endedAt: nil,
          reason: .processTermination,
          didResume: false
        )
      ]
    )
    #expect(!model.isSessionPresented)

    await model.finishInterrupted()

    guard case .completed(let completion) = model.state else {
      Issue.record("Expected the interrupted recording to complete")
      return
    }
    #expect(completion.audio == audio)
    #expect(await useCase.finishInterruptedCount == 1)
  }

  @Test("An interrupted meeting can continue in the recording screen")
  func interruptedMeetingCanResume() async {
    let audio = RecordedAudio(
      durationSeconds: 45,
      packetCount: 2_000,
      byteCount: 256_000
    )
    let useCase = RecordingUseCaseStub(
      restoredSnapshot: RecordingSnapshot(
        session: .fixture(),
        activity: .interrupted(audio)
      )
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.restore()
    await model.resumeInterrupted()

    #expect(model.state == .recording(.fixture()))
    #expect(model.isSessionPresented)
    #expect(await useCase.resumeInterruptedCount == 1)
  }

  @Test("Live transcript projection follows the use-case stream")
  func liveTranscriptProjection() async {
    let useCase = RecordingUseCaseStub(
      liveSnapshots: [
        LiveTranscriptSnapshot(
          finalSegments: [
            TranscriptSegmentCandidate(
              startSeconds: 0,
              endSeconds: 1,
              text: "已确认"
            )
          ],
          volatileSegment: TranscriptSegmentCandidate(
            startSeconds: 1,
            endSeconds: 2,
            text: "临时"
          )
        )
      ]
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    while model.liveTranscriptText.isEmpty {
      await Task.yield()
    }

    #expect(
      model.liveTranscriptText
        == "- [000.0–001.0] 已确认\n- [001.0–002.0] 临时"
    )
  }

  @Test("Audio interruption is retained as a visible gap after recovery")
  func captureInterruptionProjection() async {
    let interruptedAt = Date(timeIntervalSince1970: 1_722_470_420)
    let resumedAt = interruptedAt.addingTimeInterval(5)
    let began = RecordingCaptureEvent.interruptionBegan(
      at: interruptedAt,
      reason: .routeChange
    )
    let ended = RecordingCaptureEvent.interruptionEnded(
      at: resumedAt,
      didResume: true
    )
    let useCase = RecordingUseCaseStub(captureEvents: [began, ended])
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    for _ in 0..<100 {
      if model.interruptionGaps.first?.endedAt != nil {
        break
      }
      await Task.yield()
    }

    #expect(model.captureStatus == .active)
    #expect(
      model.interruptionGaps == [
        RecordingInterruptionGap(
          startedAt: interruptedAt,
          endedAt: resumedAt,
          reason: .routeChange,
          didResume: true
        )
      ]
    )
  }

  @Test("Failed automatic audio recovery is visible while recording")
  func captureResumeFailureProjection() async {
    let ended = RecordingCaptureEvent.interruptionEnded(
      at: Date(timeIntervalSince1970: 1_722_470_430),
      didResume: false
    )
    let useCase = RecordingUseCaseStub(captureEvents: [ended])
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    while model.captureStatus == .active {
      await Task.yield()
    }

    #expect(model.captureStatus == .resumeFailed)
  }

  @Test("Missing directory authorization prevents recording")
  func directoryAuthorizationPrecedesRecording() async {
    let recording = RecordingUseCaseStub()
    let model = HomeRecordingModel(
      recording: recording,
      directory: AuthoritativeDirectoryUseCaseStub(
        restoreError: .bookmarkMissing
      )
    )

    await model.restore()
    await model.start()

    #expect(model.directoryState == .recoveryRequired(.chooseDirectory))
    #expect(await recording.startCount == 0)
  }

  @Test("Lost directory access presents reauthorization after start fails")
  func lostDirectoryAccessRequiresReauthorization() async {
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(
        startErrors: [.authoritativeDirectoryUnavailable]
      ),
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()

    #expect(model.directoryState == .recoveryRequired(.renewAccess))
    #expect(
      model.state == .startFailed(.authoritativeDirectoryUnavailable)
    )
  }
}

private actor RecordingUseCaseStub: RecordingUseCase {
  private var startErrors: [RecordingError]
  private let stopError: RecordingError?
  private let liveSnapshots: [LiveTranscriptSnapshot]
  private let recoveryResults: [TranscriptionRecoveryResult]
  private let stopDelay: Duration?
  private let restoredSnapshot: RecordingSnapshot?
  private let capturedCaptureEvents: [RecordingCaptureEvent]
  private(set) var acknowledgementCount = 0
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var resumeInterruptedCount = 0
  private(set) var finishInterruptedCount = 0
  private(set) var recoveryCount = 0
  private(set) var deliveredCaptureEventCount = 0

  init(
    startErrors: [RecordingError] = [],
    stopError: RecordingError? = nil,
    liveSnapshots: [LiveTranscriptSnapshot] = [],
    recoveryResults: [TranscriptionRecoveryResult] = [],
    stopDelay: Duration? = nil,
    restoredSnapshot: RecordingSnapshot? = nil,
    captureEvents: [RecordingCaptureEvent] = []
  ) {
    self.startErrors = startErrors
    self.stopError = stopError
    self.liveSnapshots = liveSnapshots
    self.recoveryResults = recoveryResults
    self.stopDelay = stopDelay
    self.restoredSnapshot = restoredSnapshot
    capturedCaptureEvents = captureEvents
  }

  func restore() async throws -> RecordingSnapshot? {
    restoredSnapshot
  }

  func acknowledgeRecordingNotice() async throws {
    acknowledgementCount += 1
  }

  func start() async throws -> RecordingSnapshot {
    startCount += 1
    if !startErrors.isEmpty {
      throw startErrors.removeFirst()
    }
    return RecordingSnapshot(
      session: .fixture(),
      activity: .recording
    )
  }

  func stop() async throws -> RecordingCompletion {
    stopCount += 1
    if let stopDelay {
      try await Task.sleep(for: stopDelay)
    }
    if let stopError {
      throw stopError
    }
    return RecordingCompletion(
      session: .fixture(),
      audio: RecordedAudio(
        durationSeconds: 60,
        packetCount: 2_000,
        byteCount: 512_000
      )
    )
  }

  func finishInterrupted() async throws -> RecordingCompletion {
    finishInterruptedCount += 1
    guard
      let restoredSnapshot,
      case .interrupted(let audio) = restoredSnapshot.activity
    else {
      throw RecordingError.noActiveRecording
    }
    return RecordingCompletion(
      session: restoredSnapshot.session,
      audio: audio
    )
  }

  func resumeInterrupted() async throws -> RecordingSnapshot {
    resumeInterruptedCount += 1
    guard let restoredSnapshot else {
      throw RecordingError.noActiveRecording
    }
    return RecordingSnapshot(
      session: restoredSnapshot.session,
      activity: .recording
    )
  }

  func liveTranscript(
    meetingID: MeetingID
  ) -> AsyncStream<LiveTranscriptSnapshot> {
    let snapshots = liveSnapshots
    return AsyncStream { continuation in
      for snapshot in snapshots {
        continuation.yield(snapshot)
      }
      continuation.finish()
    }
  }

  func captureEvents(
    meetingID: MeetingID
  ) -> AsyncStream<RecordingCaptureEvent> {
    let events = capturedCaptureEvents
    return AsyncStream { continuation in
      Task {
        for event in events {
          continuation.yield(event)
          deliveredCaptureEventCount += 1
        }
        continuation.finish()
      }
    }
  }

  func catchUpLiveTranscript() async {}

  func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    recoveryCount += 1
    return recoveryResults
  }
}

private struct AuthoritativeDirectoryUseCaseStub: AuthoritativeDirectoryUseCase {
  let restoreError: DirectoryAccessError?

  init(restoreError: DirectoryAccessError? = nil) {
    self.restoreError = restoreError
  }

  func restore() async throws -> AuthoritativeDirectory? {
    if let restoreError {
      throw restoreError
    }
    return .fixture
  }

  func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    .fixture
  }
}

extension AuthoritativeDirectory {
  fileprivate static let fixture = Self(
    id: AuthoritativeDirectoryID(rawValue: "test-directory"),
    displayName: "Vault",
    kind: .userSelected
  )
}

extension RecordingSession {
  fileprivate static func fixture() -> Self {
    .init(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "C20549B1-AEE8-4F84-A250-CA3D761A84EA")!
      ),
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}
