import Domain
import Foundation

public actor GenerationWorkflow: GenerationUseCase {
  private let jobs: any GenerationJobStore
  private let assets: any GenerationFileAccess
  private let profiles: any ModelProfileExecutionAccess
  private let provider: any AIProvider
  private let diagnostics: any DiagnosticRecorder
  private let now: @Sendable () -> Date
  private let makeJobID: @Sendable () -> UUID
  private let makeAttemptID: @Sendable () -> UUID
  private let retryDelayScale: TimeInterval
  private let jitter: @Sendable (Int) -> TimeInterval
  private let onJobRegistered: (@Sendable (GenerationJob) async -> Void)?
  private let onJobNoLongerResumable: (@Sendable (UUID) async -> Void)?
  private var cancelledJobs: Set<UUID> = []
  private var executingJobs: Set<UUID> = []
  private var activeExecutionJobID: UUID?
  private var executionContexts: [UUID: GenerationExecutionContext] = [:]
  private var isDrainingQueue = false
  private var providerTasks: [UUID: Task<String, Error>] = [:]
  private var retrySleepTasks: [UUID: Task<Void, Error>] = [:]
  private var pendingProfileTasks: Set<ModelProfileTaskReference> = []

  public init(
    jobs: any GenerationJobStore,
    assets: any GenerationFileAccess,
    profiles: any ModelProfileExecutionAccess,
    provider: any AIProvider,
    diagnostics: any DiagnosticRecorder = NoopDiagnosticRecorder(),
    now: @escaping @Sendable () -> Date = Date.init,
    makeJobID: @escaping @Sendable () -> UUID = UUID.init,
    makeAttemptID: @escaping @Sendable () -> UUID = UUID.init,
    retryDelayScale: TimeInterval = 1,
    jitter: @escaping @Sendable (Int) -> TimeInterval = { attempt in
      Double.random(in: 0...(0.25 * pow(2, Double(max(0, attempt - 1)))))
    },
    onJobRegistered: (@Sendable (GenerationJob) async -> Void)? = nil,
    onJobNoLongerResumable: (@Sendable (UUID) async -> Void)? = nil
  ) {
    self.jobs = jobs
    self.assets = assets
    self.profiles = profiles
    self.provider = provider
    self.diagnostics = diagnostics
    self.now = now
    self.makeJobID = makeJobID
    self.makeAttemptID = makeAttemptID
    self.retryDelayScale = max(0, retryDelayScale)
    self.jitter = jitter
    self.onJobRegistered = onJobRegistered
    self.onJobNoLongerResumable = onJobNoLongerResumable
  }

  public func start(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    try await createGeneration(
      in: directory,
      meeting: meeting,
      replacingExternalMinutes: false,
      replacingActiveJobID: nil
    )
  }

  public func regenerate(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool
  ) async throws -> GenerationSnapshot {
    let replacingActiveJobID: UUID?
    if let active = try await jobs.activeJob(for: meeting.id) {
      if active.job.pauseReason == .externalMinutesChanged,
        !replacingExternalMinutes
      {
        throw GenerationWorkflowError.externalMinutesChanged
      }
      guard active.job.state == .paused || active.job.state == .pending else {
        throw GenerationWorkflowError.activeJobExists
      }
      replacingActiveJobID = active.job.id
    } else {
      replacingActiveJobID = nil
    }
    return try await createGeneration(
      in: directory,
      meeting: meeting,
      replacingExternalMinutes: replacingExternalMinutes,
      replacingActiveJobID: replacingActiveJobID
    )
  }

  private func createGeneration(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool,
    replacingActiveJobID: UUID?
  ) async throws -> GenerationSnapshot {
    await reconcileProfileUsage()
    if let active = try await jobs.activeJob(for: meeting.id),
      active.job.id != replacingActiveJobID
    {
      throw GenerationWorkflowError.activeJobExists
    }
    let queuedJobs = try await jobs.resumableJobs()
    let activeQueueCount =
      queuedJobs.count - (replacingActiveJobID == nil ? 0 : 1)
    guard activeQueueCount < 20 else {
      throw GenerationWorkflowError.queueFull
    }
    let transcript = try await assets.loadTranscript(
      in: directory,
      meeting: meeting
    )
    guard !transcript.revision.timeline.segments.isEmpty else {
      throw GenerationWorkflowError.transcriptNotReady
    }
    let chunkPlan = GenerationChunkPlan.make(from: transcript.revision)
    guard !chunkPlan.chunks.isEmpty else {
      throw GenerationWorkflowError.transcriptNotReady
    }
    let execution: ModelExecutionProfile
    do {
      execution = try await profiles.currentExecutionProfile()
    } catch {
      throw GenerationWorkflowError.profileUnavailable
    }

    let previousJob = try await jobs.latestJob(for: meeting.id)
    let replacedActiveJob: GenerationSnapshot?
    if let replacingActiveJobID {
      replacedActiveJob = try await jobs.load(replacingActiveJobID)
    } else {
      replacedActiveJob = nil
    }
    let previousGeneration = previousJob?.job.generationNumber ?? 0
    // Jobs created before the replacement metadata migration have no stored
    // minutes fingerprint. The catalog fingerprint is the safest available
    // baseline for that legacy completed result; a later edit is still caught
    // by the preflight comparison below.
    let previousPublishedFingerprint =
      previousJob?.job.publishedMinutesFingerprint
      ?? (previousJob?.job.state == .completed
        ? meeting.minutesContentFingerprint
        : nil)
    let strategy = MinutesGenerationStrategySelector.select(
      from: transcript.revision
    )
    let createdAt = now()
    var job = GenerationJob(
      id: makeJobID(),
      meetingID: meeting.id,
      transcriptRevisionID: transcript.revision.id,
      transcriptFingerprint: transcript.revision.contentFingerprint,
      modelProfile: execution.snapshot,
      promptVersion: strategy.promptVersionToken,
      chunkPlanVersion: chunkPlan.version,
      generationNumber: previousGeneration + 1,
      chunkCount: chunkPlan.chunks.count,
      totalSteps: chunkPlan.chunks.count + 3,
      createdAt: createdAt,
      updatedAt: createdAt,
      publishedMinutesFingerprint: previousPublishedFingerprint
    )
    pendingProfileTasks.insert(job.taskReference)
    do {
      try await profiles.registerUnfinishedTask(
        job.taskReference,
        profileID: job.modelProfile.profileID
      )
      do {
        if let replacingActiveJobID {
          try await jobs.replaceActive(replacingActiveJobID, with: job)
          // The old generation is no longer resumable after the transactional
          // replacement. Release its model-profile usage now; reconciliation
          // remains a safety net if this cleanup fails.
          if let replacedActiveJob {
            await finishTaskWithRetry(replacedActiveJob.job.taskReference)
            await onJobNoLongerResumable?(replacedActiveJob.job.id)
            executionContexts.removeValue(forKey: replacedActiveJob.job.id)
            cancelledJobs.remove(replacedActiveJob.job.id)
          }
        } else {
          try await jobs.create(job)
        }
      } catch GenerationJobStoreError.queueFull {
        throw GenerationWorkflowError.queueFull
      }
    } catch {
      await finishTaskWithRetry(job.taskReference)
      pendingProfileTasks.remove(job.taskReference)
      throw error
    }
    pendingProfileTasks.remove(job.taskReference)
    await onJobRegistered?(job)
    executionContexts[job.id] = GenerationExecutionContext(
      directory: directory,
      meeting: meeting
    )

    // Detect an externally edited minutes file before spending model budget.
    // A confirmed replacement is pinned to the file fingerprint observed at
    // confirmation time; publication checks that fingerprint again to avoid a
    // later external edit being silently overwritten.
    if meeting.assets.contains(.minutes) {
      do {
        let existingMinutes = try await assets.loadMinutesSnapshot(
          in: directory,
          meeting: meeting
        )
        if existingMinutes?.contentFingerprint != previousPublishedFingerprint {
          if replacingExternalMinutes {
            // The user has explicitly accepted replacing the currently
            // edited minutes. Pin that exact version as the replacement
            // baseline; publication performs the same comparison again
            // inside the coordinated atomic write.
            job.publishedMinutesFingerprint = existingMinutes?.contentFingerprint
            job.updatedAt = now()
          } else {
            job.publishedMinutesFingerprint = existingMinutes?.contentFingerprint
            job.updatedAt = now()
            return try await pause(
              job,
              reason: .externalMinutesChanged,
              completedSteps: []
            )
          }
        }
      } catch {
        return try await pause(
          job,
          reason: .publicationFailed,
          completedSteps: []
        )
      }
    }

    if activeExecutionJobID != nil {
      return try await jobs.load(job.id) ?? GenerationSnapshot(job: job)
    }
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
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool
  ) async throws -> GenerationSnapshot {
    if executingJobs.contains(jobID) {
      guard let snapshot = try await jobs.load(jobID) else {
        throw GenerationWorkflowError.jobNotFound
      }
      guard snapshot.job.meetingID == meeting.id else {
        throw GenerationWorkflowError.jobNotFound
      }
      executionContexts[jobID] = GenerationExecutionContext(
        directory: directory,
        meeting: meeting
      )
      return snapshot
    }
    if let activeExecutionJobID, activeExecutionJobID != jobID {
      guard let snapshot = try await jobs.load(jobID) else {
        throw GenerationWorkflowError.jobNotFound
      }
      guard snapshot.job.meetingID == meeting.id else {
        throw GenerationWorkflowError.jobNotFound
      }
      executionContexts[jobID] = GenerationExecutionContext(
        directory: directory,
        meeting: meeting
      )
      return snapshot
    }
    cancelledJobs.remove(jobID)
    executingJobs.insert(jobID)
    defer { executingJobs.remove(jobID) }
    guard var snapshot = try await jobs.load(jobID) else {
      throw GenerationWorkflowError.jobNotFound
    }
    guard snapshot.job.meetingID == meeting.id else {
      throw GenerationWorkflowError.jobNotFound
    }
    executionContexts[jobID] = GenerationExecutionContext(
      directory: directory,
      meeting: meeting
    )
    guard snapshot.job.isActive else {
      return snapshot
    }
    if snapshot.job.pauseReason == .externalMinutesChanged,
      !replacingExternalMinutes
    {
      throw GenerationWorkflowError.externalMinutesChanged
    }
    if replacingExternalMinutes {
      let confirmedMinutesFingerprint: String?
      do {
        confirmedMinutesFingerprint = try await assets.loadMinutesSnapshot(
          in: directory,
          meeting: meeting
        )?.contentFingerprint
      } catch {
        return try await pause(
          snapshot.job,
          reason: .publicationFailed,
          completedSteps: snapshot.completedSteps
        )
      }
      if snapshot.job.pauseReason == .externalMinutesChanged,
        confirmedMinutesFingerprint != snapshot.job.publishedMinutesFingerprint
      {
        var changedJob = snapshot.job
        changedJob.publishedMinutesFingerprint = confirmedMinutesFingerprint
        changedJob.updatedAt = now()
        try await jobs.saveCheckpoint(changedJob, step: nil)
        return GenerationSnapshot(
          job: changedJob,
          completedSteps: snapshot.completedSteps
        )
      }
      var confirmedJob = snapshot.job
      confirmedJob.updatedAt = now()
      try await jobs.saveCheckpoint(confirmedJob, step: nil)
      snapshot = GenerationSnapshot(job: confirmedJob, completedSteps: snapshot.completedSteps)
    }
    await onJobRegistered?(snapshot.job)
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

  public func resume(
    _ jobID: UUID,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    try await resume(
      jobID,
      in: directory,
      meeting: meeting,
      replacingExternalMinutes: false
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
      snapshot.job.state == .running
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
    retrySleepTasks[jobID]?.cancel()
    guard let snapshot = try? await jobs.load(jobID) else {
      return
    }
    guard snapshot.job.isActive else {
      cancelledJobs.remove(jobID)
      return
    }
    _ = try? await pause(
      snapshot.job,
      reason: .cancelled,
      completedSteps: snapshot.completedSteps
    )
  }

  public func activeJobs() async throws -> [GenerationSnapshot] {
    await reconcileProfileUsage()
    let snapshots = try await jobs.resumableJobs()
    return snapshots.filter { $0.job.isActive }
  }

  func resumableSnapshots() async throws -> [GenerationSnapshot] {
    try await jobs.resumableJobs()
  }

  private func execute(
    _ originalJob: GenerationJob,
    transcript: GenerationTranscriptSource,
    execution: ModelExecutionProfile,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    existingSteps: [GenerationStep] = []
  ) async throws -> GenerationSnapshot {
    if let activeExecutionJobID, activeExecutionJobID != originalJob.id {
      return GenerationSnapshot(job: originalJob, completedSteps: existingSteps)
    }
    let ownsExecutionSlot = activeExecutionJobID == nil
    if ownsExecutionSlot {
      activeExecutionJobID = originalJob.id
    }
    executingJobs.insert(originalJob.id)
    defer {
      executingJobs.remove(originalJob.id)
      if ownsExecutionSlot {
        activeExecutionJobID = nil
        Task { await self.drainQueuedJobs() }
      }
    }

    let plan = GenerationChunkPlan.make(from: transcript.revision)
    // Jobs written by #20 used one full-transcript summary step. Keep those
    // checkpoints resumable while all newly-created jobs use the pipeline below.
    if originalJob.totalSteps == 1
      || existingSteps.contains(where: { $0.kind == .summary })
    {
      let hasValidLegacyCheckpoint = existingSteps.contains {
        Self.isReusableLegacySummaryStep($0, for: originalJob)
      }
      if plan.chunks.count == 1 || hasValidLegacyCheckpoint {
        return try await executeLegacySummary(
          originalJob,
          transcript: transcript,
          execution: execution,
          in: directory,
          meeting: meeting,
          existingSteps: existingSteps
        )
      }

      // A v1 job did not persist the plan cardinality. Upgrade an incomplete
      // long job in memory while retaining its identity and generation number.
      let migratedJob = GenerationJob(
        id: originalJob.id,
        meetingID: originalJob.meetingID,
        transcriptRevisionID: originalJob.transcriptRevisionID,
        transcriptFingerprint: originalJob.transcriptFingerprint,
        modelProfile: originalJob.modelProfile,
        promptVersion: originalJob.promptVersion,
        schemaVersion: originalJob.schemaVersion,
        chunkPlanVersion: plan.version,
        generationNumber: originalJob.generationNumber,
        chunkCount: plan.chunks.count,
        totalSteps: plan.chunks.count + 3,
        createdAt: originalJob.createdAt,
        updatedAt: now(),
        state: .paused,
        progress: originalJob.progress,
        completedStepCount: originalJob.completedStepCount,
        completedChunkCount: originalJob.completedChunkCount,
        retryAttempt: originalJob.retryAttempt,
        nextRetryAt: originalJob.nextRetryAt,
        pauseReason: originalJob.pauseReason,
        publishedMinutesFingerprint: originalJob.publishedMinutesFingerprint
      )
      try await persist(migratedJob, step: nil)
      return try await execute(
        migratedJob,
        transcript: transcript,
        execution: execution,
        in: directory,
        meeting: meeting,
        existingSteps: []
      )
    }

    guard
      plan.version == originalJob.chunkPlanVersion,
      plan.chunks.count == originalJob.chunkCount
    else {
      return try await pause(
        originalJob,
        reason: .sourceChanged,
        completedSteps: []
      )
    }

    var job = originalJob
    var steps = existingSteps.filter {
      Self.isReusablePipelineStep($0, for: originalJob)
    }
    job.state = .running
    job.pauseReason = nil
    job.retryAttempt = 0
    job.nextRetryAt = nil
    job.stage = .summarizing
    job.completedChunkCount = max(
      job.completedChunkCount,
      min(job.chunkCount, steps.filter { $0.kind == .chunkSummary }.count)
    )
    job.completedStepCount = max(
      job.completedStepCount,
      min(job.totalSteps, steps.count)
    )
    job.updatedAt = now()
    try await persist(job, step: nil)
    if isCancelled(job.id) {
      return try await pause(job, reason: .cancelled, completedSteps: steps)
    }

    var chunkOutputs: [String] = []
    for chunk in plan.chunks {
      if let checkpoint = steps.first(where: {
        Self.isReusableChunkStep($0, for: job, chunk: chunk)
      }) {
        chunkOutputs.append(checkpoint.output)
        continue
      }

      let strategy = MinutesGenerationStrategyCatalog.strategy(
        forPromptVersionToken: job.promptVersion
      )
      let request = AIRequest(
        systemPrompt: strategy.chunkSystemPrompt,
        userPrompt: """
          Summarize this anchored transcript segment in the same language as the source. Keep timestamps when they clarify a decision.

          \(chunk.promptText)
          """,
        idempotencyKey: GenerationStepID.make(
          job: job,
          kind: .chunkSummary,
          index: chunk.index,
          inputFingerprint: chunk.inputFingerprint
        )
      )
      let output: String
      do {
        output = try await collectWithRetry(
          request: request,
          execution: execution,
          job: &job
        )
      } catch {
        return try await pause(
          job,
          reason: isCancelled(job.id) ? .cancelled : pauseReason(for: error),
          completedSteps: steps
        )
      }
      guard Self.isMeaningful(output) else {
        return try await pause(job, reason: .invalidResponse, completedSteps: steps)
      }

      let progress = Self.summaryProgress(
        completedChunks: chunk.index + 1,
        totalChunks: plan.chunks.count
      )
      let step = GenerationStep(
        id: GenerationStepID.make(
          job: job, kind: .chunkSummary, index: chunk.index,
          inputFingerprint: chunk.inputFingerprint),
        jobID: job.id,
        kind: .chunkSummary,
        index: chunk.index,
        inputFingerprint: chunk.inputFingerprint,
        output: output,
        progress: progress,
        completedAt: now()
      )
      steps.removeAll { $0.kind == step.kind && $0.index == step.index }
      steps.append(step)
      steps.sort { ($0.kind.rawValue, $0.index) < ($1.kind.rawValue, $1.index) }
      chunkOutputs.append(output)
      job.completedChunkCount = chunk.index + 1
      job.completedStepCount = min(job.totalSteps, steps.count)
      job.progress = max(job.progress, progress)
      job.stage = .summarizing
      job.updatedAt = now()
      try await persist(job, step: step)
      if isCancelled(job.id) {
        return try await pause(job, reason: .cancelled, completedSteps: steps)
      }
    }

    let summariesFingerprint = GenerationInputFingerprint.make(
      chunkOutputs.joined(separator: "\n---\n")
    )
    var synthesisOutput: String
    if let checkpoint = steps.first(where: {
      Self.isReusableStageStep(
        $0,
        job: job,
        kind: .synthesis,
        index: 0,
        inputFingerprint: summariesFingerprint,
        minimumProgress: 90
      )
    }) {
      synthesisOutput = checkpoint.output
    } else if chunkOutputs.count == 1 {
      // A one-chunk meeting has nothing to merge; this identity stage keeps
      // the persisted pipeline shape without charging for a duplicate request.
      synthesisOutput = chunkOutputs[0]
      let step = GenerationStep(
        id: GenerationStepID.make(
          job: job, kind: .synthesis, index: 0, inputFingerprint: summariesFingerprint),
        jobID: job.id,
        kind: .synthesis,
        index: 0,
        inputFingerprint: summariesFingerprint,
        output: synthesisOutput,
        progress: 90,
        completedAt: now()
      )
      steps.removeAll { $0.kind == step.kind && $0.index == step.index }
      steps.append(step)
      job.completedStepCount = min(job.totalSteps, steps.count)
      job.progress = max(job.progress, 90)
      job.stage = .synthesizing
      job.updatedAt = now()
      try await persist(job, step: step)
    } else {
      job.stage = .synthesizing
      job.progress = max(job.progress, 70)
      job.updatedAt = now()
      try await persist(job, step: nil)
      let strategy = MinutesGenerationStrategyCatalog.strategy(
        forPromptVersionToken: job.promptVersion
      )
      let summaries = chunkOutputs.enumerated().map {
        "## 第\($0.offset + 1)段\n\($0.element)"
      }.joined(separator: "\n\n")
      let request = AIRequest(
        systemPrompt: strategy.synthesisSystemPrompt,
        userPrompt: strategy.synthesisUserPrompt(chunkSummaries: summaries),
        idempotencyKey: GenerationStepID.make(
          job: job,
          kind: .synthesis,
          index: 0,
          inputFingerprint: summariesFingerprint
        )
      )
      do {
        synthesisOutput = try await collectWithRetry(
          request: request,
          execution: execution,
          job: &job
        )
      } catch {
        return try await pause(
          job,
          reason: isCancelled(job.id) ? .cancelled : pauseReason(for: error),
          completedSteps: steps
        )
      }
      guard Self.isMeaningful(synthesisOutput) else {
        return try await pause(job, reason: .invalidResponse, completedSteps: steps)
      }
      let step = GenerationStep(
        id: GenerationStepID.make(
          job: job, kind: .synthesis, index: 0, inputFingerprint: summariesFingerprint),
        jobID: job.id,
        kind: .synthesis,
        index: 0,
        inputFingerprint: summariesFingerprint,
        output: synthesisOutput,
        progress: 90,
        completedAt: now()
      )
      steps.removeAll { $0.kind == step.kind && $0.index == step.index }
      steps.append(step)
      job.completedStepCount = min(job.totalSteps, steps.count)
      job.progress = max(job.progress, 90)
      job.updatedAt = now()
      try await persist(job, step: step)
    }
    if isCancelled(job.id) {
      return try await pause(job, reason: .cancelled, completedSteps: steps)
    }

    let normalizationFingerprint = GenerationInputFingerprint.make(synthesisOutput)
    let normalizationStartedAt = now()
    let normalizedOutput: String
    if let checkpoint = steps.first(where: {
      Self.isReusableStageStep(
        $0,
        job: job,
        kind: .normalization,
        index: 0,
        inputFingerprint: normalizationFingerprint,
        minimumProgress: 95
      )
    }) {
      normalizedOutput = checkpoint.output
    } else {
      guard
        let normalized = MinutesOutputNormalizer.normalize(
          synthesisOutput,
          timelineBounds: Self.timelineBounds(for: transcript.revision)
        )
      else {
        return try await pause(job, reason: .invalidResponse, completedSteps: steps)
      }
      normalizedOutput = normalized.markdown
      let step = GenerationStep(
        id: GenerationStepID.make(
          job: job, kind: .normalization, index: 0, inputFingerprint: normalizationFingerprint),
        jobID: job.id,
        kind: .normalization,
        index: 0,
        inputFingerprint: normalizationFingerprint,
        output: normalizedOutput,
        progress: 95,
        completedAt: now()
      )
      steps.removeAll { $0.kind == step.kind && $0.index == step.index }
      steps.append(step)
      job.completedStepCount = min(job.totalSteps, steps.count)
      job.progress = max(job.progress, 95)
      job.stage = .normalizing
      job.updatedAt = now()
      try await persist(job, step: step)
    }
    await diagnostics.record(
      DiagnosticEvent(
        kind: .parseCompleted,
        correlation: DiagnosticCorrelation(
          meetingID: job.meetingID.rawValue,
          jobID: job.id
        ),
        durationMilliseconds: max(
          0,
          Int(now().timeIntervalSince(normalizationStartedAt) * 1_000)
        )
      )
    )
    if isCancelled(job.id) {
      return try await pause(job, reason: .cancelled, completedSteps: steps)
    }

    return try await publish(
      job,
      output: normalizedOutput,
      outputFingerprint: GenerationInputFingerprint.make(normalizedOutput),
      steps: steps,
      in: directory,
      meeting: meeting,
      transcript: transcript.revision,
      includePublicationCheckpoint: true
    )
  }

  private func executeLegacySummary(
    _ originalJob: GenerationJob,
    transcript: GenerationTranscriptSource,
    execution: ModelExecutionProfile,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    existingSteps: [GenerationStep]
  ) async throws -> GenerationSnapshot {
    var job = originalJob
    var steps = existingSteps.filter { Self.isReusableLegacySummaryStep($0, for: job) }
    job.state = .running
    job.stage = steps.isEmpty ? .summarizing : .publishing
    job.pauseReason = nil
    job.retryAttempt = 0
    job.nextRetryAt = nil
    job.updatedAt = now()
    try await persist(job, step: nil)
    if isCancelled(job.id) {
      return try await pause(job, reason: .cancelled, completedSteps: steps)
    }

    let output: String
    if let checkpoint = steps.first {
      output = checkpoint.output
    } else {
      let strategy = MinutesGenerationStrategyCatalog.strategy(
        forPromptVersionToken: job.promptVersion
      )
      let request = AIRequest(
        systemPrompt: strategy.systemPrompt,
        userPrompt: strategy.userPrompt(transcriptText: transcript.promptText),
        idempotencyKey: GenerationStepID.make(
          job: job,
          kind: .summary,
          index: 0,
          inputFingerprint: job.transcriptFingerprint
        )
      )
      do {
        output = try await collectWithRetry(
          request: request,
          execution: execution,
          job: &job
        )
      } catch {
        return try await pause(
          job,
          reason: isCancelled(job.id) ? .cancelled : pauseReason(for: error),
          completedSteps: steps
        )
      }
      guard Self.isMeaningful(output) else {
        return try await pause(job, reason: .invalidResponse, completedSteps: steps)
      }
      let step = GenerationStep(
        id: Self.legacyStepID(job: job),
        jobID: job.id,
        kind: .summary,
        index: 0,
        inputFingerprint: job.transcriptFingerprint,
        output: output,
        progress: 70,
        completedAt: now()
      )
      steps = [step]
      job.completedStepCount = max(job.completedStepCount, 1)
      job.completedChunkCount = max(job.completedChunkCount, 1)
      job.progress = max(job.progress, 70)
      job.stage = .publishing
      job.updatedAt = now()
      try await persist(job, step: step)
    }
    return try await publish(
      job,
      output: output,
      outputFingerprint: GenerationInputFingerprint.make(output),
      steps: steps,
      in: directory,
      meeting: meeting,
      transcript: transcript.revision,
      includePublicationCheckpoint: false
    )
  }

  private func publish(
    _ originalJob: GenerationJob,
    output: String,
    outputFingerprint: String,
    steps originalSteps: [GenerationStep],
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    transcript: TranscriptRevision,
    includePublicationCheckpoint: Bool
  ) async throws -> GenerationSnapshot {
    var job = originalJob
    var steps = originalSteps
    let publishStartedAt = now()
    job.stage = .publishing
    job.progress = max(job.progress, 99)
    job.completedStepCount = min(job.totalSteps, max(job.completedStepCount, steps.count))
    job.updatedAt = now()

    if includePublicationCheckpoint,
      !steps.contains(where: {
        Self.isReusableStageStep(
          $0,
          job: job,
          kind: .publication,
          index: 0,
          inputFingerprint: outputFingerprint,
          minimumProgress: 99
        )
      })
    {
      let step = GenerationStep(
        id: GenerationStepID.make(
          job: job, kind: .publication, index: 0, inputFingerprint: outputFingerprint),
        jobID: job.id,
        kind: .publication,
        index: 0,
        inputFingerprint: outputFingerprint,
        output: "candidate-ready",
        progress: 99,
        completedAt: now()
      )
      steps.removeAll { $0.kind == step.kind && $0.index == step.index }
      steps.append(step)
      job.completedStepCount = min(job.totalSteps, steps.count)
      try await persist(job, step: step)
    } else {
      try await persist(job, step: nil)
    }
    if isCancelled(job.id) {
      return try await pause(job, reason: .cancelled, completedSteps: steps)
    }

    let normalizationStartedAt = now()
    guard
      let normalized = MinutesOutputNormalizer.normalize(
        output,
        timelineBounds: Self.timelineBounds(for: transcript)
      )
    else {
      return try await pause(
        job,
        reason: .invalidResponse,
        completedSteps: steps
      )
    }
    await diagnostics.record(
      DiagnosticEvent(
        kind: .parseCompleted,
        correlation: DiagnosticCorrelation(
          meetingID: job.meetingID.rawValue,
          jobID: job.id
        ),
        durationMilliseconds: max(
          0,
          Int(now().timeIntervalSince(normalizationStartedAt) * 1_000)
        )
      )
    )
    let existingMinutesForTitle = try? await assets.loadMinutesSnapshot(
      in: directory,
      meeting: meeting
    )
    // Prefer the durable title in minutes.md over a possibly stale catalog entry.
    let previousTitle = existingMinutesForTitle?.title ?? meeting.title
    let markdown = MinutesDocumentBuilder.build(
      output: normalized.markdown,
      job: job,
      transcript: transcript,
      meeting: meeting,
      informationMayBeIncomplete: normalized.informationMayBeIncomplete,
      previousTitle: previousTitle,
      preserveUserTitle: existingMinutesForTitle?.titleUserEdited == true
    )
    do {
      let existingMinutes = try await assets.loadMinutesSnapshot(
        in: directory,
        meeting: meeting
      )
      guard
        existingMinutes?.contentFingerprint == job.publishedMinutesFingerprint
      else {
        var changedJob = job
        changedJob.publishedMinutesFingerprint = existingMinutes?.contentFingerprint
        return try await pause(
          changedJob,
          reason: .externalMinutesChanged,
          completedSteps: steps
        )
      }
    } catch {
      return try await pause(
        job,
        reason: .publicationFailed,
        completedSteps: steps
      )
    }
    do {
      try await assets.publishMinutes(
        markdown,
        in: directory,
        meeting: meeting,
        expectedTranscriptRevisionID: job.transcriptRevisionID,
        expectedTranscriptFingerprint: job.transcriptFingerprint,
        expectedExistingMinutesFingerprint: job.publishedMinutesFingerprint
      )
    } catch {
      let reason = isCancelled(job.id) ? .cancelled : pauseReason(for: error)
      var pausedJob = job
      if reason == .externalMinutesChanged {
        do {
          pausedJob.publishedMinutesFingerprint = try await assets
            .loadMinutesSnapshot(in: directory, meeting: meeting)?.contentFingerprint
        } catch {
          // Keep the last confirmed fingerprint if the file cannot be read.
        }
      }
      return try await pause(
        pausedJob,
        reason: reason,
        completedSteps: steps
      )
    }
    if isCancelled(job.id) {
      return try await pause(job, reason: .cancelled, completedSteps: steps)
    }

    job.publishedMinutesFingerprint = GenerationInputFingerprint.make(markdown)
    job.state = .completed
    job.stage = .completed
    job.progress = 100
    job.completedAt = now()
    job.updatedAt = job.completedAt ?? now()
    try await persist(job, step: nil)
    await diagnostics.record(
      DiagnosticEvent(
        kind: .publishCompleted,
        correlation: DiagnosticCorrelation(
          meetingID: job.meetingID.rawValue,
          jobID: job.id
        ),
        durationMilliseconds: max(
          0,
          Int(now().timeIntervalSince(publishStartedAt) * 1_000)
        )
      )
    )
    await finishTaskWithRetry(job.taskReference)
    await onJobNoLongerResumable?(job.id)
    cancelledJobs.remove(job.id)
    return GenerationSnapshot(job: job, completedSteps: steps)
  }

  private func collectWithRetry(
    request: AIRequest,
    execution: ModelExecutionProfile,
    job: inout GenerationJob
  ) async throws -> String {
    var attempt = 0
    while true {
      guard !isCancelled(job.id) else {
        throw CancellationError()
      }
      attempt += 1
      job.retryAttempt = attempt
      job.nextRetryAt = nil
      let attemptID = makeAttemptID()
      let correlation = DiagnosticCorrelation(
        meetingID: job.meetingID.rawValue,
        jobID: job.id,
        stepID: request.idempotencyKey,
        attemptID: attemptID
      )
      let requestStartedAt = now()
      do {
        let provider = self.provider
        await diagnostics.record(
          DiagnosticEvent(
            timestamp: requestStartedAt,
            kind: .requestSent,
            correlation: correlation,
            host: execution.snapshot.baseURL.host,
            model: execution.snapshot.model,
            attempt: attempt
          )
        )
        let providerTask = Task(priority: nil) {
          try await Self.collect(
            provider: provider,
            request: request,
            execution: execution,
            diagnosticContext: DiagnosticProviderContext(
              correlation: correlation,
              host: execution.snapshot.baseURL.host,
              model: execution.snapshot.model
            )
          )
        }
        providerTasks[job.id] = providerTask
        let output: String
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
        job.retryAttempt = 0
        job.nextRetryAt = nil
        await diagnostics.record(
          DiagnosticEvent(
            kind: .responseCompleted,
            correlation: correlation,
            durationMilliseconds: max(
              0,
              Int(now().timeIntervalSince(requestStartedAt) * 1_000)
            ),
            host: execution.snapshot.baseURL.host,
            model: execution.snapshot.model,
            attempt: attempt
          )
        )
        return output
      } catch {
        providerTasks.removeValue(forKey: job.id)
        guard Self.isRetryable(error), attempt < 3 else {
          if Self.isRetryable(error), attempt >= 3 {
            throw GenerationRetryExhausted(underlying: error)
          }
          throw error
        }
        let delay = Self.retryDelay(for: error, attempt: attempt, jitter: jitter(attempt))
        await diagnostics.record(
          DiagnosticEvent(
            kind: .retryScheduled,
            correlation: correlation,
            attempt: attempt,
            retryAfterMilliseconds: max(0, Int(delay * 1_000)),
            errorCode: Self.diagnosticErrorCode(error)
          )
        )
        job.nextRetryAt = now().addingTimeInterval(delay)
        job.updatedAt = now()
        try await persist(job, step: nil)
        guard !isCancelled(job.id) else {
          throw CancellationError()
        }
        let nanoseconds = Self.retryNanoseconds(
          delay: delay,
          scale: retryDelayScale
        )
        let sleepTask = Task<Void, Error> {
          try await Task.sleep(nanoseconds: nanoseconds)
        }
        retrySleepTasks[job.id] = sleepTask
        do {
          try await withTaskCancellationHandler {
            try await sleepTask.value
          } onCancel: {
            sleepTask.cancel()
          }
        } catch {
          retrySleepTasks.removeValue(forKey: job.id)
          throw error
        }
        retrySleepTasks.removeValue(forKey: job.id)
        guard !isCancelled(job.id) else {
          throw CancellationError()
        }
        // The checkpoint keeps the step boundary durable while the request is
        // backing off; completed steps remain unchanged and are never billed twice.
      }
    }
  }

  private static func collect(
    provider: any AIProvider,
    request: AIRequest,
    execution: ModelExecutionProfile,
    diagnosticContext: DiagnosticProviderContext?
  ) async throws -> String {
    var output = ""
    var completed = false
    for try await event in provider.generate(
      request,
      profile: execution.snapshot,
      apiKey: execution.apiKey,
      diagnosticContext: diagnosticContext
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
    await diagnostics.record(
      DiagnosticEvent(
        kind: .checkpointSaved,
        correlation: DiagnosticCorrelation(
          meetingID: job.meetingID.rawValue,
          jobID: job.id,
          stepID: step?.id
        ),
        attempt: job.retryAttempt
      )
    )
  }

  private func drainQueuedJobs() async {
    guard !isDrainingQueue, activeExecutionJobID == nil else {
      return
    }
    isDrainingQueue = true
    defer { isDrainingQueue = false }

    while activeExecutionJobID == nil {
      guard
        let snapshots = try? await jobs.resumableJobs(),
        let next = snapshots.first(where: {
          $0.job.state == .pending && executionContexts[$0.job.id] != nil
        }),
        let context = executionContexts[next.job.id]
      else {
        return
      }

      do {
        let result = try await resume(
          next.job.id,
          in: context.directory,
          meeting: context.meeting
        )
        if result.job.state == .completed {
          executionContexts.removeValue(forKey: next.job.id)
        } else if result.job.state != .pending {
          return
        }
      } catch {
        executionContexts.removeValue(forKey: next.job.id)
      }
    }
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
    if error is GenerationRetryExhausted {
      return .retryExhausted
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
      case .externalMinutesChanged:
        return .externalMinutesChanged
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
    case .rateLimited, .rateLimitedWithRetryAfter:
      return .rateLimited
    case .serviceUnavailable:
      return .serviceUnavailable
    case .retryableRequest:
      return .retryableRequest
    case .requestTooLarge:
      return .requestTooLarge
    case .networkUnavailable:
      return .networkUnavailable
    case .invalidResponse, .incompatibleResponse, .insecureBaseURL,
      .requestRejected:
      return .invalidResponse
    }
  }

  private func isCancelled(_ jobID: UUID) -> Bool {
    cancelledJobs.contains(jobID) || Task.isCancelled
  }

  private static func diagnosticErrorCode(_ error: Error) -> String {
    switch error {
    case is CancellationError:
      return "cancelled"
    case is AIProviderError:
      return "provider"
    case is GenerationRetryExhausted:
      return "retry_exhausted"
    default:
      return "unknown"
    }
  }

  private static func legacyStepID(job: GenerationJob) -> String {
    "\(job.id.uuidString)/\(job.promptVersion)/summary/0/\(job.transcriptFingerprint)"
  }

  private static func isReusableLegacySummaryStep(
    _ step: GenerationStep,
    for job: GenerationJob
  ) -> Bool {
    step.id
      == legacyStepID(job: job)
      && step.jobID == job.id
      && step.kind == .summary
      && step.index == 0
      && step.inputFingerprint == job.transcriptFingerprint
      && step.progress >= 70
      && isMeaningful(step.output)
  }

  private static func isReusablePipelineStep(
    _ step: GenerationStep,
    for job: GenerationJob
  ) -> Bool {
    guard step.jobID == job.id, isMeaningful(step.output) else {
      return false
    }
    switch step.kind {
    case .chunkSummary:
      return step.index >= 0
        && step.index < job.chunkCount
        && step.id
          == GenerationStepID.make(
            job: job,
            kind: step.kind,
            index: step.index,
            inputFingerprint: step.inputFingerprint
          )
    case .synthesis, .normalization:
      return step.index == 0
        && step.id
          == GenerationStepID.make(
            job: job,
            kind: step.kind,
            index: step.index,
            inputFingerprint: step.inputFingerprint
          )
    case .publication:
      return step.index == 0
        && step.output == "candidate-ready"
        && step.id
          == GenerationStepID.make(
            job: job,
            kind: step.kind,
            index: step.index,
            inputFingerprint: step.inputFingerprint
          )
    case .summary:
      return false
    }
  }

  private static func isReusableChunkStep(
    _ step: GenerationStep,
    for job: GenerationJob,
    chunk: GenerationChunk
  ) -> Bool {
    step.kind == .chunkSummary
      && step.index == chunk.index
      && step.inputFingerprint == chunk.inputFingerprint
      && step.progress
        >= summaryProgress(
          completedChunks: chunk.index + 1,
          totalChunks: job.chunkCount
        )
      && step.id
        == GenerationStepID.make(
          job: job,
          kind: .chunkSummary,
          index: chunk.index,
          inputFingerprint: chunk.inputFingerprint
        )
      && isMeaningful(step.output)
  }

  private static func isReusableStageStep(
    _ step: GenerationStep,
    job: GenerationJob,
    kind: GenerationStepKind,
    index: Int,
    inputFingerprint: String,
    minimumProgress: Int
  ) -> Bool {
    step.jobID == job.id
      && step.kind == kind
      && step.index == index
      && step.inputFingerprint == inputFingerprint
      && step.progress >= minimumProgress
      && step.id
        == GenerationStepID.make(
          job: job,
          kind: kind,
          index: index,
          inputFingerprint: inputFingerprint
        )
      && (kind == .publication ? step.output == "candidate-ready" : isMeaningful(step.output))
  }

  private static func summaryProgress(
    completedChunks: Int,
    totalChunks: Int
  ) -> Int {
    guard totalChunks > 0 else { return 0 }
    return min(
      70,
      Int((70.0 * Double(completedChunks) / Double(totalChunks)).rounded(.down))
    )
  }

  private static func isRetryable(_ error: Error) -> Bool {
    guard let error = error as? AIProviderError else { return false }
    switch error {
    case .networkUnavailable, .rateLimited, .rateLimitedWithRetryAfter:
      return true
    case .retryableRequest(let statusCode):
      return statusCode == 408
    case .serviceUnavailable(let statusCode):
      return [500, 502, 503, 504].contains(statusCode)
    case .insecureBaseURL, .authentication, .modelUnavailable,
      .requestRejected, .requestTooLarge, .incompatibleResponse,
      .invalidResponse:
      return false
    }
  }

  private static func retryDelay(
    for error: Error,
    attempt: Int,
    jitter: TimeInterval
  ) -> TimeInterval {
    let exponential = min(30, pow(2, Double(max(0, attempt - 1))))
    let retryAfter: TimeInterval
    if let providerError = error as? AIProviderError,
      case .rateLimitedWithRetryAfter(let seconds) = providerError
    {
      retryAfter = max(0, seconds)
    } else {
      retryAfter = 0
    }
    return min(
      300,
      max(exponential, min(300, retryAfter)) + max(0, jitter)
    )
  }

  private static func retryNanoseconds(
    delay: TimeInterval,
    scale: TimeInterval
  ) -> UInt64 {
    let seconds = min(300, max(0, delay) * max(0, scale))
    let nanoseconds = seconds * 1_000_000_000
    guard nanoseconds.isFinite else {
      return UInt64.max
    }
    return UInt64(min(Double(UInt64.max), nanoseconds))
  }

  private static func isMeaningful(_ output: String) -> Bool {
    MinutesOutputNormalizer.normalize(output) != nil
  }

  private static func timelineBounds(for transcript: TranscriptRevision) -> ClosedRange<Double>? {
    let duration = transcript.timeline.audioDurationSeconds
    guard duration.isFinite, duration > 0 else { return nil }
    return 0...duration
  }
}

private struct GenerationRetryExhausted: Error, Sendable {
  let underlying: Error
}

private struct GenerationExecutionContext: Sendable {
  let directory: AuthoritativeDirectory
  let meeting: MeetingIndexEntry
}

enum MinutesDocumentBuilder {
  static func build(
    output: String,
    job: GenerationJob,
    transcript: TranscriptRevision,
    meeting: MeetingIndexEntry,
    informationMayBeIncomplete: Bool,
    previousTitle: String? = nil,
    preserveUserTitle: Bool = false
  ) -> String {
    let body = stripLeadingTitle(
      from: output.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let title = MinutesTitleResolver.resolve(
      markdown: output,
      previousTitle: previousTitle ?? meeting.title,
      meetingStartedAt: meeting.createdAt,
      preserveUserTitle: preserveUserTitle
    )
    let escapedTitle =
      title
      .replacingOccurrences(of: "\"", with: "\\\"")
    let userEditedFlag = preserveUserTitle ? "true" : "false"
    return [
      "---",
      "schemaVersion: 1",
      "title: \"\(escapedTitle)\"",
      "titleUserEdited: \(userEditedFlag)",
      "generationJobID: \(job.id.uuidString)",
      "generationNumber: \(job.generationNumber)",
      "promptVersion: \(job.promptVersion)",
      "transcriptRevisionID: \(transcript.id)",
      "transcriptFingerprint: \(transcript.contentFingerprint)",
      "model: \(job.modelProfile.model)",
      "informationMayBeIncomplete: \(informationMayBeIncomplete)",
      "---",
      "",
      "# \(title)",
      "",
      body,
      "",
    ].joined(separator: "\n")
  }

  /// Avoid duplicating the H1 when the model already provided one.
  private static func stripLeadingTitle(from markdown: String) -> String {
    var lines = markdown.components(separatedBy: "\n")
    while let first = lines.first,
      first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      lines.removeFirst()
    }
    guard let first = lines.first else {
      return markdown
    }
    let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("#") {
      lines.removeFirst()
      while let next = lines.first,
        next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        lines.removeFirst()
      }
      return lines.joined(separator: "\n")
    }
    return markdown
  }
}
