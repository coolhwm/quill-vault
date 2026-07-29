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
    let model = HomeRecordingModel(recording: useCase)

    await model.start()

    #expect(model.state == .recording(.fixture()))
    #expect(model.isSessionPresented)
  }

  @Test("First recording presents notice before retrying start")
  func noticeIsAcknowledged() async {
    let useCase = RecordingUseCaseStub(startErrors: [.recordingConsentRequired])
    let model = HomeRecordingModel(recording: useCase)

    await model.start()
    #expect(model.isRecordingNoticePresented)

    await model.acknowledgeNoticeAndStart()
    #expect(await useCase.acknowledgementCount == 1)
    #expect(model.state == .recording(.fixture()))
  }

  @Test("Stop failure keeps the focused screen available for retry")
  func stopFailureCanRetry() async {
    let useCase = RecordingUseCaseStub(stopError: .recordingWriteFailed)
    let model = HomeRecordingModel(recording: useCase)
    await model.start()

    await model.stop()

    #expect(
      model.state == .finishFailed(.fixture(), .recordingWriteFailed)
    )
    #expect(model.isSessionPresented)
  }

  @Test("Invalid audio exits the recording screen without claiming success")
  func invalidAudioExitsFocusedScreen() async {
    let useCase = RecordingUseCaseStub(stopError: .invalidRecordedAudio)
    let model = HomeRecordingModel(recording: useCase)
    await model.start()

    await model.stop()

    #expect(model.state == .startFailed(.invalidRecordedAudio))
    #expect(!model.isSessionPresented)
  }
}

private actor RecordingUseCaseStub: RecordingUseCase {
  private var startErrors: [RecordingError]
  private let stopError: RecordingError?
  private(set) var acknowledgementCount = 0

  init(
    startErrors: [RecordingError] = [],
    stopError: RecordingError? = nil
  ) {
    self.startErrors = startErrors
    self.stopError = stopError
  }

  func restore() async throws -> RecordingSnapshot? {
    nil
  }

  func acknowledgeRecordingNotice() async throws {
    acknowledgementCount += 1
  }

  func start() async throws -> RecordingSnapshot {
    if !startErrors.isEmpty {
      throw startErrors.removeFirst()
    }
    return RecordingSnapshot(
      session: .fixture(),
      activity: .recording
    )
  }

  func stop() async throws -> RecordingCompletion {
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
