import Domain
import Testing

@testable import Application

@Suite("Retrying recording use case")
struct RetryingRecordingUseCaseTests {
  @Test("Foreground transcript catch-up reaches the resolved use case")
  func forwardsForegroundCatchUp() async {
    let resolved = RecordingUseCaseCatchUpSpy()
    let subject = RetryingRecordingUseCase {
      resolved
    }

    await subject.catchUpLiveTranscript()

    #expect(await resolved.catchUpCount == 1)
  }
}

private actor RecordingUseCaseCatchUpSpy: RecordingUseCase {
  private(set) var catchUpCount = 0

  func restore() async throws -> RecordingSnapshot? {
    nil
  }

  func acknowledgeRecordingNotice() async throws {}

  func start() async throws -> RecordingSnapshot {
    throw RecordingError.noActiveRecording
  }

  func catchUpLiveTranscript() async {
    catchUpCount += 1
  }

  func stop() async throws -> RecordingCompletion {
    throw RecordingError.noActiveRecording
  }

  func recoverPendingTranscriptions() async throws
    -> [TranscriptionRecoveryResult]
  {
    []
  }
}
