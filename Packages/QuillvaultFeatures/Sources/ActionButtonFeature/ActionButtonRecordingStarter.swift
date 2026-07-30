import Application

public struct ActionButtonRecordingStarter: Sendable {
  private let startAction: @Sendable () async -> RecordingQuickStartOutcome

  public init(
    start: @escaping @Sendable () async -> RecordingQuickStartOutcome
  ) {
    startAction = start
  }

  public func start() async -> RecordingQuickStartOutcome {
    await startAction()
  }
}
