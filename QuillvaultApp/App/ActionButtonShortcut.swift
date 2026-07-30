import ActionButtonFeature
import AppIntents
import Application
import Foundation
import HomeFeature

@MainActor
final class ActionButtonRecordingCoordinator {
  private let router: AppRouter
  private let recordingModel: HomeRecordingModel
  private let quickStart: any RecordingQuickStartUseCase

  init(
    router: AppRouter,
    recordingModel: HomeRecordingModel,
    quickStart: any RecordingQuickStartUseCase
  ) {
    self.router = router
    self.recordingModel = recordingModel
    self.quickStart = quickStart
  }

  func start() async -> RecordingQuickStartOutcome {
    router.selectedTab = .home
    let outcome = await quickStart.start()
    recordingModel.presentQuickStartOutcome(outcome)
    return outcome
  }
}

struct QuillvaultAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartFaceToFaceSessionIntent(),
      phrases: [
        "Start a face-to-face meeting with \(.applicationName)",
        "在 \(.applicationName) 开始面对面会议",
      ],
      shortTitle: LocalizedStringResource("actionButton.start.shortTitle"),
      systemImageName: "record.circle"
    )
  }

  static let shortcutTileColor: ShortcutTileColor = .blue
}
