import ActionButtonFeature
import AppIntents
import SwiftUI

@main
struct QuillvaultApp: App {
  @State private var compositionRoot: AppCompositionRoot
  @State private var didRunActionButtonUITest = false

  init() {
    let compositionRoot = AppCompositionRoot()
    _compositionRoot = State(initialValue: compositionRoot)
    let actionButtonDependency = ActionButtonRecordingStarter {
      await compositionRoot.actionButtonCoordinator.start()
    }
    AppDependencyManager.shared.add(dependency: actionButtonDependency)
    QuillvaultAppShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      AppRootView(
        router: compositionRoot.router,
        recordingModel: compositionRoot.recordingModel,
        meetingsModel: compositionRoot.meetingsModel,
        settingsModel: compositionRoot.settingsModel,
        lifecycleCoordinator: compositionRoot.lifecycleCoordinator
      )
      .task {
        guard
          !didRunActionButtonUITest,
          ProcessInfo.processInfo.arguments.contains(
            "-ui-test-action-button"
          )
        else {
          return
        }
        didRunActionButtonUITest = true
        _ = await compositionRoot.actionButtonCoordinator.start()
      }
    }
  }
}
