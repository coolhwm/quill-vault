import Domain
import Foundation

public actor GenerationWorkflow: GenerationUseCase {
  private let jobs: any GenerationJobStore
  private let assets: any GenerationFileAccess
  private let profiles: any ModelProfileExecutionAccess
  private let provider: any AIProvider
  private let now: @Sendable () -> Date
  private let makeJobID: @Sendable () -> UUID
  private var cancelledJobs: Set<UUID> = []
  private var executingJobs: Set<UUID> = []
  private var providerTasks: [UUID: Task<String, Error>] = [:]
  private var pendingProfileTasks: Set<ModelProfileTaskReference> = []

  public init(
    jobs: any GenerationJobStore,
    assets: any GenerationFileAccess,
    profiles: any ModelProfileExecutionAccess,
    provider: any AIProvider,
    now: @escaping @Sendable () -> Date = Date.init,
    makeJobID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.jobs = jobs
    self.assets = assets
    self.profiles = profiles
    self.provider = provider
    self.now = now
    self.makeJobID = makeJobID
  }

  public func start(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    await reconcileProfileUsage()
    if try await jobs.activeJob(for: meeting.id) != nil {
      throw GenerationWorkflowError.activeJobExists
    }
    let transcript = try await assets.loadTranscript(
      in: directory,
      meeting: meeting
    )
    guard !transcript.revision.timeline.segments.isEmpty else {
      throw GenerationWorkflowError.transcriptNotReady
    }
    let execution: ModelExecutionProfile
    do {
      execution = try await profiles.currentExecutionProfile()
    } catch {
      throw GenerationWorkflowError.profileUnavailable
    }

    let previousGeneration =
      try await jobs.resumableJobs().filter {
        $0.job.meetingID == meeting.id
      }.map(\.job.generationNumber).max() ?? 0
    let createdAt = now()
    let job = GenerationJob(
      id: makeJobID(),
      meetingID: meeting.id,
      transcriptRevisionID: transcript.revision.id,
      transcriptFingerprint: transcript.revision.contentFingerprint,
      modelProfile: execution.snapshot,
      generationNumber: previousGeneration + 1,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    pendingProfileTasks.insert(job.taskReference)
    do {
      try await profiles.registerUnfinishedTask(
        job.taskReference,
        profileID: job.modelProfile.profileID
      )
      try await jobs.create(job)
    } catch {
      await finishTaskWithRetry(job.taskReference)
      pendingProfileTasks.remove(job.taskReference)
      throw error
    }
    pendingProfileTasks.remove(job.taskReference)
    return try await execute(
      job,
      transcript: transcript,
      execution: execution,
      in: directory,
      meeting: meeting
    )
  }

  public func resume(
    _ jobID: UUID,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    if executingJobs.contains(jobID) {
      guard let snapshot = try await jobs.load(jobID) else {
        throw GenerationWorkflowError.jobNotFound
      }
      return snapshot
    }
    cancelledJobs.remove(jobID)
    executingJobs.insert(jobID)
    defer { executingJobs.remove(jobID) }
    guard let snapshot = try await jobs.load(jobID) else {
      throw GenerationWorkflowError.jobNotFound
    }
    guard snapshot.job.meetingID == meeting.id else {
      throw GenerationWorkflowError.jobNotFound
    }
    if snapshot.job.state == .completed {
      return snapshot
    }
    if cancelledJobs.contains(jobID) {
      return try await pause(
        snapshot.job,
        reason: .cancelled,
        completedSteps: snapshot.completedSteps
      )
    }
    await reconcileProfileUsage()
    if cancelledJobs.contains(jobID) {
      return try await pause(
        snapshot.job,
        reason: .cancelled,
        completedSteps: snapshot.completedSteps
      )
    }
    let transcript = try await assets.loadTranscript(
      in: directory,
      meeting: meeting
    )
    if cancelledJobs.contains(jobID) {
      return try await pause(
        snapshot.job,
        reason: .cancelled,
        completedSteps: snapshot.completedSteps
      )
    }
    guard
      transcript.revision.id == snapshot.job.transcriptRevisionID,
      transcript.revision.contentFingerprint == snapshot.job.transcriptFingerprint
    else {
      return try await pause(
        snapshot.job,
        reason: .sourceChanged,
        completedSteps: snapshot.completedSteps
      )
    }
    let execution: ModelExecutionProfile
    do {
      execution = try await profiles.executionProfile(
        for: snapshot.job.modelProfile
      )
    } catch {
      return try await pause(
        snapshot.job,
        reason: pauseReason(for: error),
        completedSteps: snapshot.completedSteps
      )
    }
    return try await execute(
      snapshot.job,
      transcript: transcript,
      execution: execution,
      in: directory,
      meeting: meeting,
      existingSteps: snapshot.completedSteps
    )
  }

  public func load(
    meetingID: MeetingID
  ) async throws -> GenerationSnapshot? {
    await reconcileProfileUsage()
    guard let snapshot = try await jobs.activeJob(for: meetingID) else {
      return nil
    }
    guard
      !executingJobs.contains(snapshot.job.id),
      snapshot.job.state == .pending || snapshot.job.state == .running
    else {
      return snapshot
    }
    var recovered = snapshot.job
    recovered.state = .paused
    recovered.stage = .pending
    recovered.pauseReason = .unavailable
    recovered.updatedAt = now()
    try await jobs.saveCheckpoint(recovered, step: nil)
    return GenerationSnapshot(
      job: recovered,
      completedSteps: snapshot.completedSteps
    )
  }

  public func cancel(_ jobID: UUID) async {
    cancelledJobs.insert(jobID)
    providerTasks[jobID]?.cancel()
    guard let snapshot = try? await jobs.load(jobID) else {
      return
    }
    guard snapshot.job.state != .completed else {
      cancelledJobs.remove(jobID)
      return
    }
    _ = try? await pause(
      snapshot.job,
      reason: .cancelled,
      completedSteps: snapshot.completedSteps
    )
  }

  private func execute(
    _ originalJob: GenerationJob,
    transcript: GenerationTranscriptSource,
    execution: ModelExecutionProfile,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    existingSteps: [GenerationStep] = []
  ) async throws -> GenerationSnapshot {
    let ownsExecutionSlot = !executingJobs.contains(originalJob.id)
    if ownsExecutionSlot {
      executingJobs.insert(originalJob.id)
    }
    defer {
      if ownsExecutionSlot {
        executingJobs.remove(originalJob.id)
      }
    }
    var job = originalJob
    let reusableStep = existingSteps.first(where: {
      Self.isReusableSummaryStep($0, for: originalJob)
    })
    var steps = reusableStep.map { [$0] } ?? []
    job.state = .running
    job.stage = steps.isEmpty ? .summarizing : .publishing
    job.pauseReason = nil
    job.updatedAt = now()
    try await persist(job, step: nil)
    if cancelledJobs.contains(job.id) || Task.isCancelled {
      return try await pause(
        job,
        reason: .cancelled,
        completedSteps: steps
      )
    }

    let output: String
    if let step = steps.first(where: {
      $0.kind == .summary
        && $0.inputFingerprint == job.transcriptFingerprint
    }) {
      output = step.output
    } else {
      let request = AIRequest(
        systemPrompt: """
          You create concise, readable meeting minutes. Return only useful Markdown text. Do not include API keys, local paths, or fenced Mermaid blocks. Missing optional details must not prevent a readable summary.
          """,
        userPrompt: """
          Summarize this meeting transcript in the same language as the transcript. Include a short title, a concise overview, decisions, action items with an explicit or待确认负责人, and open questions when present. Keep the response readable even if the transcript is short.

          \(transcript.promptText)
          """
      )
      do {
        let provider = self.provider
        let providerTask = Task(priority: nil) {
          try await Self.collect(
            provider: provider,
            request: request,
            execution: execution
          )
        }
        providerTasks[job.id] = providerTask
        do {
          output = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await providerTask.value
          } onCancel: {
            providerTask.cancel()
          }
        } catch {
          providerTasks.removeValue(forKey: job.id)
          throw error
        }
        providerTasks.removeValue(forKey: job.id)
      } catch {
        return try await pause(
          job,
          reason: cancelledJobs.contains(job.id) || Task.isCancelled
            ? .cancelled
            : pauseReason(for: error),
          completedSteps: steps
        )
      }
      if cancelledJobs.contains(job.id) || Task.isCancelled {
        return try await pause(
          job,
          reason: .cancelled,
          completedSteps: steps
        )
      }
      guard Self.isMeaningful(output) else {
        return try await pause(
          job,
          reason: .invalidResponse,
          completedSteps: steps
        )
      }
      let step = GenerationStep(
        id: Self.stepID(
          job: job,
          kind: .summary,
          index: 0,
          inputFingerprint: job.transcriptFingerprint
        ),
        jobID: job.id,
        kind: .summary,
        index: 0,
        inputFingerprint: job.transcriptFingerprint,
        output: output,
        progress: 70,
        completedAt: now()
      )
      steps = [step]
      job.completedStepCount = 1
      job.progress = max(job.progress, 70)
      job.stage = .publishing
      job.updatedAt = now()
      try await persist(job, step: step)
      if cancelledJobs.contains(job.id) || Task.isCancelled {
        return try await pause(
          job,
          reason: .cancelled,
          completedSteps: steps
        )
      }
    }

    job.stage = .publishing
    job.progress = max(job.progress, 99)
    job.updatedAt = now()
    try await persist(job, step: nil)
    if cancelledJobs.contains(job.id) || Task.isCancelled {
      return try await pause(
        job,
        reason: .cancelled,
        completedSteps: steps
      )
    }
    let markdown = MinutesDocumentBuilder.build(
      output: output,
      job: job,
      transcript: transcript.revision
    )
    do {
      try await assets.publishMinutes(
        markdown,
        in: directory,
        meeting: meeting,
        expectedTranscriptRevisionID: job.transcriptRevisionID,
        expectedTranscriptFingerprint: job.transcriptFingerprint
      )
    } catch {
      return try await pause(
        job,
        reason: cancelledJobs.contains(job.id) || Task.isCancelled
          ? .cancelled
          : pauseReason(for: error),
        completedSteps: steps
      )
    }
    if cancelledJobs.contains(job.id) || Task.isCancelled {
      return try await pause(
        job,
        reason: .cancelled,
        completedSteps: steps
      )
    }

    if cancelledJobs.contains(job.id) || Task.isCancelled {
      return try await pause(
        job,
        reason: .cancelled,
        completedSteps: steps
      )
    }

    job.state = .completed
    job.stage = .completed
    job.progress = 100
    job.completedAt = now()
    job.updatedAt = job.completedAt ?? now()
    try await persist(job, step: nil)
    await finishTaskWithRetry(job.taskReference)
    cancelledJobs.remove(job.id)
    return GenerationSnapshot(job: job, completedSteps: steps)
  }

  private static func collect(
    provider: any AIProvider,
    request: AIRequest,
    execution: ModelExecutionProfile
  ) async throws -> String {
    var output = ""
    var completed = false
    for try await event in provider.generate(
      request,
      profile: execution.snapshot,
      apiKey: execution.apiKey
    ) {
      try Task.checkCancellation()
      switch event {
      case .textDelta(let delta):
        output.append(delta)
      case .completed:
        completed = true
      }
    }
    guard completed else {
      throw AIProviderError.invalidResponse
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func persist(
    _ job: GenerationJob,
    step: GenerationStep?
  ) async throws {
    try await jobs.saveCheckpoint(job, step: step)
  }

  private func pause(
    _ originalJob: GenerationJob,
    reason: GenerationPauseReason,
    completedSteps: [GenerationStep]
  ) async throws -> GenerationSnapshot {
    var job = originalJob
    job.state = .paused
    job.stage = .pending
    job.pauseReason = reason
    job.updatedAt = now()
    try await persist(job, step: nil)
    return GenerationSnapshot(job: job, completedSteps: completedSteps)
  }

  private func reconcileProfileUsage() async {
    guard let snapshots = try? await jobs.resumableJobs() else {
      return
    }
    var taskReferences = Set(snapshots.map { $0.job.taskReference })
    taskReferences.formUnion(pendingProfileTasks)
    try? await profiles.reconcileUnfinishedTasks(keeping: taskReferences)
  }

  private func finishTaskWithRetry(
    _ task: ModelProfileTaskReference
  ) async {
    for attempt in 0..<3 {
      do {
        try await profiles.finishTask(task)
        return
      } catch {
        guard attempt < 2 else { return }
        try? await Task.sleep(for: .milliseconds(50 * (attempt + 1)))
      }
    }
  }

  private func pauseReason(for error: Error) -> GenerationPauseReason {
    if error is CancellationError {
      return .cancelled
    }
    if let credentialError = error as? ModelCredentialError {
      switch credentialError {
      case .unavailableUntilFirstUnlock:
        return .credentialsUnavailable
      case .notFound, .unavailable:
        return .authenticationRequired
      }
    }
    if let error = error as? GenerationFileError {
      switch error {
      case .sourceChanged:
        return .sourceChanged
      case .publicationFailed:
        return .publicationFailed
      case .directoryUnavailable, .meetingUnavailable, .transcriptUnavailable:
        return .unavailable
      }
    }
    guard let error = error as? AIProviderError else {
      return .unavailable
    }
    switch error {
    case .authentication:
      return .authenticationRequired
    case .modelUnavailable:
      return .modelUnavailable
    case .rateLimited:
      return .rateLimited
    case .serviceUnavailable:
      return .serviceUnavailable
    case .retryableRequest:
      return .retryableRequest
    case .networkUnavailable:
      return .networkUnavailable
    case .invalidResponse, .incompatibleResponse, .insecureBaseURL,
      .requestRejected:
      return .invalidResponse
    }
  }

  private static func stepID(
    job: GenerationJob,
    kind: GenerationStepKind,
    index: Int,
    inputFingerprint: String
  ) -> String {
    "\(job.id.uuidString)/\(job.promptVersion)/\(kind.rawValue)/\(index)/\(inputFingerprint)"
  }

  private static func isReusableSummaryStep(
    _ step: GenerationStep,
    for job: GenerationJob
  ) -> Bool {
    step.id
      == stepID(
        job: job,
        kind: .summary,
        index: 0,
        inputFingerprint: job.transcriptFingerprint
      )
      && step.jobID == job.id
      && step.kind == .summary
      && step.index == 0
      && step.inputFingerprint == job.transcriptFingerprint
      && step.progress >= 70
      && isMeaningful(step.output)
  }

  private static func isMeaningful(_ output: String) -> Bool {
    output.unicodeScalars.contains { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || (scalar.value >= 0x3400 && scalar.value <= 0x9FFF)
    }
  }
}

private enum MinutesDocumentBuilder {
  static func build(
    output: String,
    job: GenerationJob,
    transcript: TranscriptRevision
  ) -> String {
    [
      "---",
      "schemaVersion: 1",
      "generationJobID: \(job.id.uuidString)",
      "generationNumber: \(job.generationNumber)",
      "transcriptRevisionID: \(transcript.id)",
      "transcriptFingerprint: \(transcript.contentFingerprint)",
      "model: \(job.modelProfile.model)",
      "informationMayBeIncomplete: false",
      "---",
      "",
      "# 结构化纪要",
      "",
      output.trimmingCharacters(in: .whitespacesAndNewlines),
      "",
    ].joined(separator: "\n")
  }
}
