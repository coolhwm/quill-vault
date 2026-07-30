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

    #expect(model.liveTranscriptText == "已确认\n临时")
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
  private(set) var acknowledgementCount = 0
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var recoveryCount = 0

  init(
    startErrors: [RecordingError] = [],
    stopError: RecordingError? = nil,
    liveSnapshots: [LiveTranscriptSnapshot] = [],
    recoveryResults: [TranscriptionRecoveryResult] = [],
    stopDelay: Duration? = nil
  ) {
    self.startErrors = startErrors
    self.stopError = stopError
    self.liveSnapshots = liveSnapshots
    self.recoveryResults = recoveryResults
    self.stopDelay = stopDelay
  }

  func restore() async throws -> RecordingSnapshot? {
    nil
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
