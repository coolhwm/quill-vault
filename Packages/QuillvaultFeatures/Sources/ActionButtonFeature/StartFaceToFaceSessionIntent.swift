import AppIntents
import Application
import Foundation

public struct StartFaceToFaceSessionIntent: AppIntent {
  public static let title = LocalizedStringResource(
    "actionButton.start.title"
  )
  public static let description = IntentDescription(
    LocalizedStringResource("actionButton.start.description")
  )
  public static let supportedModes: IntentModes = .foreground(.immediate)

  @Dependency
  private var recordingStarter: ActionButtonRecordingStarter

  public init() {}

  init(recordingStarter: ActionButtonRecordingStarter) {
    _recordingStarter = Dependency()
    self.recordingStarter = recordingStarter
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await recordingStarter.start()
    return .result(dialog: dialog(for: outcome))
  }

  private func dialog(
    for outcome: RecordingQuickStartOutcome
  ) -> IntentDialog {
    switch outcome {
    case .started:
      IntentDialog(
        LocalizedStringResource("actionButton.result.started")
      )
    case .alreadyActive:
      IntentDialog(
        LocalizedStringResource("actionButton.result.alreadyActive")
      )
    case .requiresInterruptedDecision:
      IntentDialog(
        LocalizedStringResource("actionButton.result.interrupted")
      )
    case .requiresAppAttention(.recordingNotice):
      IntentDialog(
        LocalizedStringResource("actionButton.result.notice")
      )
    case .requiresAppAttention(.microphonePermission):
      IntentDialog(
        LocalizedStringResource("actionButton.result.microphone")
      )
    case .requiresAppAttention(.authoritativeDirectory):
      IntentDialog(
        LocalizedStringResource("actionButton.result.directory")
      )
    case .requiresAppAttention(.insufficientStorage):
      IntentDialog(
        LocalizedStringResource("actionButton.result.storage")
      )
    case .requiresAppAttention(.retry):
      IntentDialog(
        LocalizedStringResource("actionButton.result.retry")
      )
    case .alreadyStarting:
      IntentDialog(
        LocalizedStringResource("actionButton.result.starting")
      )
    case .cancelled:
      IntentDialog(
        LocalizedStringResource("actionButton.result.cancelled")
      )
    }
  }
}
