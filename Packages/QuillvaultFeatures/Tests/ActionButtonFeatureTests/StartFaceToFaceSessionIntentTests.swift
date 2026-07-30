import Application
import Testing

@testable import ActionButtonFeature

@Suite("Start face-to-face session intent")
struct StartFaceToFaceSessionIntentTests {
  @Test("The intent delegates once to the injected application boundary")
  func delegatesToApplicationBoundary() async throws {
    let spy = ActionButtonRecordingStartingSpy()
    let intent = StartFaceToFaceSessionIntent(
      recordingStarter: ActionButtonRecordingStarter {
        await spy.start()
      }
    )

    _ = try await intent.perform()

    #expect(await spy.startCount == 1)
  }
}

private actor ActionButtonRecordingStartingSpy {
  private(set) var startCount = 0

  func start() async -> RecordingQuickStartOutcome {
    startCount += 1
    return .requiresAppAttention(
      .authoritativeDirectory(.chooseDirectory)
    )
  }
}
