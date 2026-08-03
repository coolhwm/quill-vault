import Application
import BackgroundTasks
import Domain
import Foundation
import OSLog

/// Bridges persisted generation jobs to iOS 26 continued-processing tasks.
/// The task identifier is derived from the durable job ID, so a process restart
/// never needs an in-memory map to reconnect system work to an application job.
@MainActor
final class GenerationBackgroundCoordinator {
  private static let logger = Logger(
    subsystem: "com.coolhwm.Quillvault",
    category: "GenerationBackground"
  )
  private static let taskIdentifierPrefix =
    "com.coolhwm.Quillvault.continued-generation."

  private var library: (any MeetingLibraryUseCase)?
  private var generation: (any GenerationUseCase)?
  private var recovery: (any GenerationRecoveryUseCase)?
  private let diagnostics: any DiagnosticRecorder
  private var registeredTaskIdentifiers: Set<String> = []

  init(
    diagnostics: any DiagnosticRecorder = NoopDiagnosticRecorder(),
    resumableJobIDs: [UUID] = []
  ) {
    self.diagnostics = diagnostics
    guard #available(iOS 26.0, *) else {
      return
    }
    for jobID in resumableJobIDs {
      guard registerLaunchHandler(for: Self.taskIdentifier(for: jobID)) else {
        Task {
          await diagnostics.record(
            DiagnosticEvent(
              kind: .backgroundCompleted,
              correlation: DiagnosticCorrelation(jobID: jobID),
              errorCode: "registration_failed"
            )
          )
        }
        Self.logger.error("Could not register a pending continued generation task handler.")
        continue
      }
    }
  }

  func configure(
    library: any MeetingLibraryUseCase,
    generation: (any GenerationUseCase)?
  ) {
    self.library = library
    self.generation = generation
    self.recovery = generation as? any GenerationRecoveryUseCase
  }

  func schedule(jobID: UUID) async {
    guard #available(iOS 26.0, *) else {
      return
    }
    let identifier = Self.taskIdentifier(for: jobID)
    guard registerLaunchHandler(for: identifier) else {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundCompleted,
          correlation: DiagnosticCorrelation(jobID: jobID),
          errorCode: "registration_failed"
        )
      )
      Self.logger.error("Could not register continued generation task handler.")
      return
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: String(localized: "minutes.background.title"),
      subtitle: String(localized: "minutes.background.subtitle")
    )
    request.strategy = .queue
    request.requiredResources = []
    do {
      try BGTaskScheduler.shared.submit(request)
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundScheduled,
          correlation: DiagnosticCorrelation(jobID: jobID)
        )
      )
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundCompleted,
          correlation: DiagnosticCorrelation(jobID: jobID),
          errorCode: "submit_failed"
        )
      )
      Self.logger.error("Could not submit continued generation task.")
    }
  }

  func cancel(jobID: UUID) async {
    if let generation {
      await generation.cancel(jobID)
    }
    cancelScheduledTask(jobID: jobID)
  }

  func cancelScheduledTask(jobID: UUID) {
    if #available(iOS 26.0, *) {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier(for: jobID))
    }
  }

  func reconcile() async {
    guard let library, let recovery else {
      return
    }
    guard let snapshot = try? await library.restore() else {
      Self.logger.error("Could not restore the meeting library for recovery.")
      return
    }
    do {
      try await recovery.reconcile(in: snapshot)
    } catch {
      Self.logger.error("Could not reconcile persisted generation jobs.")
    }
  }

  @available(iOS 26.0, *)
  private func registerLaunchHandler(for identifier: String) -> Bool {
    guard !registeredTaskIdentifiers.contains(identifier) else {
      return true
    }
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier,
      using: DispatchQueue.main
    ) { [weak self] task in
      Task { @MainActor [weak self] in
        await self?.handle(task)
      }
    }
    if registered {
      registeredTaskIdentifiers.insert(identifier)
    }
    return registered
  }

  private func handle(_ task: BGTask) async {
    guard
      let continuedTask = task as? BGContinuedProcessingTask,
      let jobID = Self.jobID(from: task.identifier)
    else {
      task.setTaskCompleted(success: false)
      return
    }
    await diagnostics.record(
      DiagnosticEvent(
        kind: .backgroundStarted,
        correlation: DiagnosticCorrelation(jobID: jobID)
      )
    )
    await run(jobID: jobID, task: continuedTask)
  }

  private func run(
    jobID: UUID,
    task: BGContinuedProcessingTask
  ) async {
    task.expirationHandler = { [weak self] in
      Task { @MainActor [weak self] in
        await self?.cancel(jobID: jobID)
      }
    }
    defer {
      task.expirationHandler = nil
    }

    guard let library, let generation else {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundCompleted,
          correlation: DiagnosticCorrelation(jobID: jobID),
          errorCode: "unavailable"
        )
      )
      task.setTaskCompleted(success: false)
      return
    }
    guard let librarySnapshot = try? await library.restore() else {
      Self.logger.error("Could not restore the meeting library for a background task.")
      task.setTaskCompleted(success: false)
      return
    }

    var targetMeeting: MeetingIndexEntry?
    var targetSnapshot: GenerationSnapshot?
    for meeting in librarySnapshot.meetings {
      if let snapshot = try? await generation.load(meetingID: meeting.id),
        snapshot.job.id == jobID
      {
        targetMeeting = meeting
        targetSnapshot = snapshot
        break
      }
    }
    guard let targetMeeting else {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundCompleted,
          correlation: DiagnosticCorrelation(jobID: jobID),
          errorCode: "job_not_found"
        )
      )
      task.setTaskCompleted(success: false)
      return
    }
    if targetSnapshot?.job.pauseReason == .cancelled {
      task.setTaskCompleted(success: false)
      return
    }

    let progressTask = Task { @MainActor in
      while !Task.isCancelled {
        if let snapshot = try? await generation.load(meetingID: targetMeeting.id) {
          Self.update(task: task, snapshot: snapshot)
          if snapshot.job.state == .completed {
            return
          }
        }
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
    defer {
      progressTask.cancel()
    }

    do {
      let snapshot = try await generation.resume(
        jobID,
        in: librarySnapshot.directory,
        meeting: targetMeeting
      )
      Self.update(task: task, snapshot: snapshot)
      if snapshot.job.state == .pending {
        await schedule(jobID: jobID)
      }
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundCompleted,
          correlation: DiagnosticCorrelation(
            meetingID: targetMeeting.id.rawValue,
            jobID: jobID
          ),
          errorCode: snapshot.job.state == .completed ? "success" : "paused"
        )
      )
      task.setTaskCompleted(success: snapshot.job.state == .completed)
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          kind: .backgroundCompleted,
          correlation: DiagnosticCorrelation(
            meetingID: targetMeeting.id.rawValue,
            jobID: jobID
          ),
          errorCode: "failed"
        )
      )
      task.setTaskCompleted(success: false)
    }
  }

  private static func update(
    task: BGContinuedProcessingTask,
    snapshot: GenerationSnapshot
  ) {
    task.progress.totalUnitCount = 100
    task.progress.completedUnitCount = Int64(snapshot.job.progress)
    task.updateTitle(
      String(localized: "minutes.background.title"),
      subtitle: "\(stageText(for: snapshot.job.stage)) · "
        + String(localized: "minutes.background.progress \(snapshot.job.progress)")
    )
  }

  private static func stageText(for stage: GenerationStage) -> String {
    switch stage {
    case .pending:
      String(localized: "minutes.background.stage.pending")
    case .summarizing:
      String(localized: "minutes.background.stage.summarizing")
    case .synthesizing:
      String(localized: "minutes.background.stage.synthesizing")
    case .normalizing:
      String(localized: "minutes.background.stage.normalizing")
    case .publishing:
      String(localized: "minutes.background.stage.publishing")
    case .completed:
      String(localized: "minutes.background.stage.completed")
    }
  }

  private static func taskIdentifier(for jobID: UUID) -> String {
    taskIdentifierPrefix + jobID.uuidString
  }

  private static func jobID(from identifier: String) -> UUID? {
    guard identifier.hasPrefix(taskIdentifierPrefix) else {
      return nil
    }
    return UUID(uuidString: String(identifier.dropFirst(taskIdentifierPrefix.count)))
  }
}
