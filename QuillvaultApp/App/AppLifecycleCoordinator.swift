import HomeFeature

@MainActor
final class AppLifecycleCoordinator {
  private let recordingModel: HomeRecordingModel

  init(recordingModel: HomeRecordingModel) {
    self.recordingModel = recordingModel
  }

  func didBecomeActive() async {
    await recordingModel.catchUpLiveTranscript()
  }
}
