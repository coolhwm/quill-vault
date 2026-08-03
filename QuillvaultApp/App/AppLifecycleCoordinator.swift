import HomeFeature

@MainActor
final class AppLifecycleCoordinator {
  private let recordingModel: HomeRecordingModel
  private let generationBackgroundCoordinator: GenerationBackgroundCoordinator?

  init(
    recordingModel: HomeRecordingModel,
    generationBackgroundCoordinator: GenerationBackgroundCoordinator? = nil
  ) {
    self.recordingModel = recordingModel
    self.generationBackgroundCoordinator = generationBackgroundCoordinator
  }

  func didBecomeActive() async {
    await recordingModel.catchUpLiveTranscript()
    guard !recordingModel.isSessionPresented else {
      return
    }
    await generationBackgroundCoordinator?.reconcile()
  }
}
