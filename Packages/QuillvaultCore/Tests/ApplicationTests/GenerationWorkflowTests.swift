import Application
import Domain
import Foundation
import Testing

@Suite("Generation workflow")
struct GenerationWorkflowTests {
  @Test("Publishes a short transcript with a durable checkpoint and 100% read-back completion")
  func publishesShortTranscript() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("已确认下一步。"))
    let registrations = GenerationJobRegistrationCollector()
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      makeJobID: { UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")! },
      onJobRegistered: { job in
        await registrations.append(job)
      }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.job.progress == 100)
    #expect(snapshot.completedSteps.count == 4)
    #expect(snapshot.job.chunkCount == 1)
    #expect(snapshot.job.completedChunkCount == 1)
    #expect(await assets.publishedMarkdown?.contains("已确认下一步。") == true)
    let requests = provider.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.userPrompt.contains(source.transcript.promptText) == true)
    #expect(await profiles.registered.count == 1)
    #expect(await profiles.finished.count == 1)
    #expect(await jobs.load(snapshot.job.id)?.job.progress == 100)
    #expect(await registrations.ids == [snapshot.job.id])
  }

  @Test("Regeneration creates a new generation from the current model and latest transcript")
  func regenerationCreatesNewGeneration() async throws {
    let source = try GenerationTestSource()
    let assets = VersionedMinutesAssets(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let alternate = source.alternateExecution
    let profiles = SwitchingExecutionProfiles(initial: source.execution)
    let provider = SequencedGenerationProvider(
      results: [
        .success("第一版纪要"),
        .success("第二版纪要"),
      ]
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let first = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )
    await profiles.select(alternate)
    let regenerated = try await workflow.regenerate(
      in: source.directory,
      meeting: source.meetingWithMinutes
    )

    #expect(first.job.state == .completed)
    #expect(regenerated.job.state == .completed)
    #expect(regenerated.job.generationNumber == first.job.generationNumber + 1)
    #expect(regenerated.job.modelProfile == alternate.snapshot)
    #expect(regenerated.job.transcriptFingerprint == source.transcript.revision.contentFingerprint)
    #expect(provider.requestCount == 2)
    #expect(await assets.minutes?.contains("第二版纪要") == true)
    #expect(await jobs.load(first.job.id)?.job.state == .completed)
  }

  @Test("Legacy completed generations use the catalog fingerprint as a safe baseline")
  func legacyCompletedGenerationRegeneratesWithoutFalseConflict() async throws {
    let source = try GenerationTestSource()
    let legacyMinutes = "legacy minutes"
    let assets = VersionedMinutesAssets(source: source.transcript)
    await assets.replaceMinutes(legacyMinutes)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("新纪要"))
    let createdAt = source.meeting.createdAt
    let legacyJob = GenerationJob(
      id: UUID(uuidString: "23232323-2323-2323-2323-232323232323")!,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      generationNumber: 1,
      createdAt: createdAt,
      updatedAt: createdAt,
      completedAt: createdAt,
      state: .completed,
      stage: .completed,
      progress: 100
    )
    try await jobs.create(legacyJob)
    let meeting = MeetingIndexEntry(
      id: source.meeting.id,
      createdAt: source.meeting.createdAt,
      relativeDirectory: source.meeting.relativeDirectory,
      assets: [.recording, .transcript, .minutes],
      durationSeconds: source.meeting.durationSeconds,
      minutesContentFingerprint: GenerationInputFingerprint.make(legacyMinutes)
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let regenerated = try await workflow.regenerate(
      in: source.directory,
      meeting: meeting
    )

    #expect(regenerated.job.state == .completed)
    #expect(regenerated.job.generationNumber == 2)
    #expect(provider.recordedRequests().count == 1)
    #expect(await assets.minutes?.contains("新纪要") == true)
  }

  @Test("Regeneration supersedes a paused generation without leaving a stale resumable task")
  func regenerationSupersedesPausedGeneration() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let failure = AIProviderError.serviceUnavailable(statusCode: 503)
    let provider = SequencedGenerationProvider(
      results: [
        .failure(failure),
        .failure(failure),
        .failure(failure),
        .failure(failure),
        .success("替代版本纪要"),
      ]
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let paused = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )
    #expect(paused.job.state == .paused)
    #expect(paused.job.pauseReason == .retryExhausted)

    let replacement = try await workflow.regenerate(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(replacement.job.state == .completed)
    #expect(replacement.job.generationNumber == paused.job.generationNumber + 1)
    #expect(await jobs.load(paused.job.id)?.job.state == .superseded)
    #expect(await jobs.activeJob(for: source.meeting.id) == nil)
    #expect(await profiles.finished.contains(paused.job.taskReference))
    #expect(await profiles.finished.contains(replacement.job.taskReference))

    let staleResume = try await workflow.resume(
      paused.job.id,
      in: source.directory,
      meeting: source.meeting
    )
    #expect(staleResume.job.state == .superseded)
    #expect(await provider.requestCount == 5)
  }

  @Test("An external minutes edit pauses a recoverable generation before model work")
  func externalMinutesEditPausesRecoverableGeneration() async throws {
    let source = try GenerationTestSource()
    let assets = VersionedMinutesAssets(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = SwitchingExecutionProfiles(initial: source.execution)
    let provider = SequencedGenerationProvider(
      results: [
        .success("第一版纪要"),
        .success("确认后的纪要"),
      ]
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    _ = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )
    await assets.replaceMinutes("用户在文件中补充的内容")

    let paused = try await workflow.regenerate(
      in: source.directory,
      meeting: source.meetingWithMinutes
    )

    #expect(paused.job.state == .paused)
    #expect(paused.job.pauseReason == .externalMinutesChanged)
    #expect(provider.requestCount == 1)
    #expect(await assets.minutes == "用户在文件中补充的内容")
    #expect(await jobs.activeJob(for: source.meeting.id)?.job.id == paused.job.id)

    let resumed = try await workflow.resume(
      paused.job.id,
      in: source.directory,
      meeting: source.meetingWithMinutes,
      replacingExternalMinutes: true
    )

    #expect(resumed.job.state == .completed)
    #expect(resumed.job.generationNumber == paused.job.generationNumber)
    #expect(await assets.minutes?.contains("确认后的纪要") == true)
    #expect(provider.requestCount == 2)
  }

  @Test("Explicit replacement confirmation accepts an edited completed minutes file")
  func explicitReplacementConfirmationAcceptsEditedCompletedMinutes() async throws {
    let source = try GenerationTestSource()
    let assets = VersionedMinutesAssets(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = SequencedGenerationProvider(
      results: [
        .success("第一版纪要"),
        .success("确认后的纪要"),
      ]
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let first = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )
    await assets.replaceMinutes("用户在文件中补充的内容")

    let replaced = try await workflow.regenerate(
      in: source.directory,
      meeting: source.meetingWithMinutes,
      replacingExternalMinutes: true
    )

    #expect(first.job.state == .completed)
    #expect(replaced.job.state == .completed)
    #expect(replaced.job.generationNumber == first.job.generationNumber + 1)
    #expect(await assets.minutes?.contains("确认后的纪要") == true)
    #expect(provider.requestCount == 2)
  }

  @Test("A provider failure pauses the job without publishing or damaging source assets")
  func providerFailureIsRecoverable() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(
      source: source.transcript,
      existingMinutes: "previous minutes"
    )
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(
      result: .failure(AIProviderError.serviceUnavailable(statusCode: 503))
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .retryExhausted)
    #expect(await assets.publishCount == 0)
    #expect(await assets.existingMinutes == "previous minutes")
    #expect(await profiles.finished.isEmpty)
  }

  @Test("A long transcript is summarized in chunks and merged once")
  func longTranscriptUsesChunkPipeline() async throws {
    let source = try GenerationTestSource()
    let longTranscript = GenerationTranscriptSource(
      revision: TranscriptRevision(
        meetingID: source.meeting.id,
        localeIdentifier: "zh-CN",
        timeline: TranscriptTimeline(
          audioDurationSeconds: 60,
          segments: (0..<3).map { index in
            TranscriptSegment(
              id: "long-\(index)",
              startSeconds: Double(index * 20),
              endSeconds: Double((index + 1) * 20),
              text: String(repeating: "第\(index)段信息", count: 1_000)
            )
          }
        )
      )
    )
    let assets = GenerationAssetsStub(source: longTranscript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("模型输出"))
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.job.chunkCount == 3)
    #expect(snapshot.job.completedChunkCount == 3)
    #expect(snapshot.job.progress == 100)
    #expect(snapshot.completedSteps.count == 6)
    #expect(provider.recordedRequests().count == 4)
    #expect(
      provider.recordedRequests().dropLast().allSatisfy { request in
        request.systemPrompt.contains("transcript segment")
      })
    #expect(provider.recordedRequests().last?.systemPrompt.contains("Merge chunk") == true)
  }

  @Test("A validated chunk checkpoint is reused after resume")
  func resumesFromChunkCheckpointWithoutDuplicateBilling() async throws {
    let source = try GenerationTestSource()
    let longTranscript = GenerationTranscriptSource(
      revision: TranscriptRevision(
        meetingID: source.meeting.id,
        localeIdentifier: "zh-CN",
        timeline: TranscriptTimeline(
          audioDurationSeconds: 60,
          segments: (0..<2).map { index in
            TranscriptSegment(
              id: "checkpoint-(index)",
              startSeconds: Double(index * 30),
              endSeconds: Double((index + 1) * 30),
              text: String(repeating: "第(index)段已完成信息", count: 900)
            )
          }
        )
      )
    )
    let plan = GenerationChunkPlan.make(from: longTranscript.revision)
    #expect(plan.chunks.count == 2)
    let jobs = InMemoryGenerationJobStore()
    let jobID = UUID(uuidString: "19191919-1919-1919-1919-191919191919")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    var job = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: longTranscript.revision.id,
      transcriptFingerprint: longTranscript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      chunkPlanVersion: plan.version,
      chunkCount: plan.chunks.count,
      totalSteps: plan.chunks.count + 3,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .summarizing,
      progress: 35,
      completedStepCount: 1,
      completedChunkCount: 1
    )
    let firstChunk = plan.chunks[0]
    let checkpoint = GenerationStep(
      id: GenerationStepID.make(
        job: job,
        kind: .chunkSummary,
        index: firstChunk.index,
        inputFingerprint: firstChunk.inputFingerprint
      ),
      jobID: job.id,
      kind: .chunkSummary,
      index: firstChunk.index,
      inputFingerprint: firstChunk.inputFingerprint,
      output: "第一段已持久化。",
      progress: 35,
      completedAt: createdAt
    )
    try await jobs.create(job)
    job.updatedAt = createdAt.addingTimeInterval(1)
    try await jobs.saveCheckpoint(job, step: checkpoint)

    let provider = RecordingGenerationProvider(result: .success("恢复后的摘要。"))
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: GenerationAssetsStub(source: longTranscript),
      profiles: ExecutionProfilesStub(profile: source.execution),
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.resume(
      jobID,
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.completedSteps.count == 5)
    #expect(provider.recordedRequests().count == 2)
    #expect(provider.recordedRequests().first?.userPrompt.contains("第0段已完成信息") == false)
    #expect(await (jobs.load(jobID)?.completedSteps.contains(checkpoint) ?? false))
  }

  @Test("A legacy long job migrates before resuming the chunk pipeline")
  func migratesLegacyLongJob() async throws {
    let source = try GenerationTestSource()
    let longTranscript = GenerationTranscriptSource(
      revision: TranscriptRevision(
        meetingID: source.meeting.id,
        localeIdentifier: "zh-CN",
        timeline: TranscriptTimeline(
          audioDurationSeconds: 60,
          segments: (0..<2).map { index in
            TranscriptSegment(
              id: "legacy-(index)",
              startSeconds: Double(index * 30),
              endSeconds: Double((index + 1) * 30),
              text: String(repeating: "旧任务第(index)段信息", count: 900)
            )
          }
        )
      )
    )
    let jobs = InMemoryGenerationJobStore()
    let jobID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let legacyJob = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: longTranscript.revision.id,
      transcriptFingerprint: longTranscript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .pending,
      pauseReason: .unavailable
    )
    try await jobs.create(legacyJob)
    let provider = RecordingGenerationProvider(result: .success("迁移后的输出。"))
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: GenerationAssetsStub(source: longTranscript),
      profiles: ExecutionProfilesStub(profile: source.execution),
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.resume(
      jobID,
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.job.chunkCount == 2)
    #expect(snapshot.completedSteps.count == 5)
    #expect(provider.recordedRequests().count == 3)
  }

  @Test("Authentication failure is surfaced without automatic retries")
  func authenticationFailureDoesNotRetry() async throws {
    let source = try GenerationTestSource()
    let provider = RecordingGenerationProvider(
      result: .failure(AIProviderError.authentication)
    )
    let workflow = GenerationWorkflow(
      jobs: InMemoryGenerationJobStore(),
      assets: GenerationAssetsStub(source: source.transcript),
      profiles: ExecutionProfilesStub(profile: source.execution),
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .authenticationRequired)
    #expect(provider.recordedRequests().count == 1)
  }

  @Test("A transient provider failure retries once and does not duplicate checkpoints")
  func transientFailureRetriesAndResumes() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = SequencedGenerationProvider(
      results: [
        .failure(AIProviderError.serviceUnavailable(statusCode: 503)),
        .success("重试后摘要"),
      ]
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.job.retryAttempt == 0)
    #expect(provider.requestCount == 2)
    #expect(snapshot.completedSteps.filter { $0.kind == .chunkSummary }.count == 1)
    #expect(await assets.publishedMarkdown?.contains("重试后摘要") == true)
  }

  @Test("Cancelling during retry backoff releases the generation slot immediately")
  func cancellationDuringRetryBackoffIsImmediate() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let provider = SequencedGenerationProvider(
      results: [
        .failure(AIProviderError.serviceUnavailable(statusCode: 503)),
        .success("不应在取消后再次请求。"),
      ]
    )
    let jobID = UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: GenerationAssetsStub(source: source.transcript),
      profiles: ExecutionProfilesStub(profile: source.execution),
      provider: provider,
      makeJobID: { jobID },
      retryDelayScale: 1,
      jitter: { _ in 0 }
    )

    let generationTask = Task {
      try await workflow.start(in: source.directory, meeting: source.meeting)
    }
    while provider.requestCount < 1 {
      try await Task.sleep(for: .milliseconds(10))
    }

    var retryWasPersisted = false
    for _ in 0..<100 {
      if let snapshot = await jobs.load(jobID), snapshot.job.nextRetryAt != nil {
        retryWasPersisted = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(retryWasPersisted)

    await workflow.cancel(jobID)
    let snapshot = try await generationTask.value

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .cancelled)
    #expect(provider.requestCount == 1)
  }

  @Test("A second meeting is queued while one generation is active")
  func generationQueueIsSingleFlight() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = BlockingGenerationProvider()
    let firstJobID = UUID(uuidString: "16161616-1616-1616-1616-161616161616")!
    let secondJobID = UUID(uuidString: "18181818-1818-1818-1818-181818181818")!
    let jobIDs = GenerationIDSequence(ids: [firstJobID, secondJobID])
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      makeJobID: { jobIDs.next() }
    )
    let first = Task {
      try await workflow.start(in: source.directory, meeting: source.meeting)
    }
    await provider.waitUntilStarted()

    let secondMeeting = MeetingIndexEntry(
      id: MeetingID(
        rawValue: UUID(uuidString: "17171717-1717-1717-1717-171717171717")!
      ),
      createdAt: source.meeting.createdAt.addingTimeInterval(1),
      relativeDirectory: "meeting-2",
      assets: [.recording, .transcript],
      durationSeconds: 20
    )
    let queued = try await workflow.start(
      in: source.directory,
      meeting: secondMeeting
    )

    #expect(queued.job.state == .pending)
    #expect(queued.job.progress == 0)
    #expect(provider.requestCount == 1)
    #expect(queued.job.id == secondJobID)
    #expect((await jobs.resumableJobs()).map(\.job.id) == [firstJobID, secondJobID])

    await workflow.cancel(firstJobID)
    #expect(await provider.waitUntilTerminated())
    provider.finish()
    _ = try await first.value

    await provider.waitUntilRequestCount(2)
    #expect(provider.requestCount == 2)
    await workflow.cancel(secondJobID)
    #expect(await provider.waitUntilTerminated())
    provider.finish()
    let secondSnapshot = try await workflow.load(meetingID: secondMeeting.id)
    #expect(secondSnapshot?.job.state == .paused)
    #expect(secondSnapshot?.job.pauseReason == .cancelled)
  }

  @Test("Regeneration replaces a queued pending generation before it starts")
  func regenerationReplacesQueuedPendingGeneration() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = SwitchingExecutionProfiles(initial: source.execution)
    let provider = BlockingGenerationProvider()
    let firstJobID = UUID(uuidString: "19191919-1919-1919-1919-191919191919")!
    let queuedJobID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
    let replacementJobID = UUID(uuidString: "21212121-2121-2121-2121-212121212121")!
    let jobIDs = GenerationIDSequence(
      ids: [firstJobID, queuedJobID, replacementJobID]
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      makeJobID: { jobIDs.next() }
    )
    let first = Task {
      try await workflow.start(in: source.directory, meeting: source.meeting)
    }
    await provider.waitUntilStarted()

    let queuedMeeting = MeetingIndexEntry(
      id: MeetingID(
        rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
      ),
      createdAt: source.meeting.createdAt.addingTimeInterval(1),
      relativeDirectory: "meeting-queued",
      assets: [.recording, .transcript],
      durationSeconds: 20
    )
    let queued = try await workflow.start(
      in: source.directory,
      meeting: queuedMeeting
    )
    await profiles.select(source.alternateExecution)
    let replacement = try await workflow.regenerate(
      in: source.directory,
      meeting: queuedMeeting
    )

    #expect(queued.job.id == queuedJobID)
    #expect(queued.job.state == .pending)
    #expect(replacement.job.id == replacementJobID)
    #expect(replacement.job.state == .pending)
    #expect(replacement.job.generationNumber == queued.job.generationNumber + 1)
    #expect(replacement.job.modelProfile == source.alternateExecution.snapshot)
    #expect(await jobs.load(queuedJobID)?.job.state == .superseded)
    #expect(provider.requestCount == 1)
    #expect((await jobs.resumableJobs()).map(\.job.id) == [firstJobID, replacementJobID])

    await workflow.cancel(firstJobID)
    #expect(await provider.waitUntilTerminated())
    provider.finish()
    _ = try await first.value
    await provider.waitUntilRequestCount(2)
    await workflow.cancel(replacementJobID)
    #expect(await provider.waitUntilTerminated())
    provider.finish()
  }

  @Test("A publication failure pauses the job and preserves the existing minutes")
  func publicationFailureIsRecoverable() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(
      source: source.transcript,
      existingMinutes: "previous minutes",
      publicationError: .publicationFailed
    )
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("新的摘要。"))
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .publicationFailed)
    #expect(await assets.publishCount == 0)
    #expect(await assets.existingMinutes == "previous minutes")
  }

  @Test("Cancellation pauses a running job without publishing")
  func cancellationIsRecoverable() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = BlockingGenerationProvider()
    let jobID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      makeJobID: { jobID }
    )

    let generationTask = Task {
      try await workflow.start(
        in: source.directory,
        meeting: source.meeting
      )
    }
    await provider.waitUntilStarted()
    await workflow.cancel(jobID)
    #expect(await provider.waitUntilTerminated())
    provider.finish()
    let snapshot = try await generationTask.value

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .cancelled)
    #expect(await assets.publishCount == 0)
  }

  @Test("Cancelling the caller task also cancels the provider request")
  func callerCancellationIsRecoverable() async throws {
    let source = try GenerationTestSource()
    let assets = GenerationAssetsStub(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = BlockingGenerationProvider()
    let jobID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      makeJobID: { jobID }
    )

    let generationTask = Task {
      try await workflow.start(
        in: source.directory,
        meeting: source.meeting
      )
    }
    await provider.waitUntilStarted()
    generationTask.cancel()

    #expect(await provider.waitUntilTerminated())
    let snapshot = try await generationTask.value

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .cancelled)
    #expect(await assets.publishCount == 0)
  }

  @Test("Cancellation during publication cannot be overwritten by completion")
  func publicationCancellationIsRecoverable() async throws {
    let source = try GenerationTestSource()
    let assets = BlockingPublicationAssets(source: source.transcript)
    let jobs = InMemoryGenerationJobStore()
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("待发布摘要。"))
    let jobID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      makeJobID: { jobID }
    )

    let generationTask = Task {
      try await workflow.start(
        in: source.directory,
        meeting: source.meeting
      )
    }
    await assets.waitUntilPublicationStarted()
    await workflow.cancel(jobID)
    await assets.finishPublication()
    let snapshot = try await generationTask.value

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .cancelled)
    #expect(snapshot.job.progress == 99)
    #expect(await profiles.finished.isEmpty)
  }

  @Test("A cold-start running job becomes resumable instead of blocking a new attempt")
  func coldStartRecoversRunningJob() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let job = GenerationJob(
      id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .running,
      stage: .summarizing,
      progress: 20
    )
    try await jobs.create(job)
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: GenerationAssetsStub(source: source.transcript),
      profiles: ExecutionProfilesStub(profile: source.execution),
      provider: RecordingGenerationProvider(result: .success("摘要"))
    )

    let snapshot = try await workflow.load(meetingID: source.meeting.id)

    #expect(snapshot?.job.state == .paused)
    #expect(snapshot?.job.pauseReason == .unavailable)
    #expect(await jobs.load(job.id)?.job.state == .paused)
  }

  @Test("Lifecycle reconciliation resumes persisted pending work")
  func lifecycleReconciliationResumesPendingWork() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let job = GenerationJob(
      id: UUID(uuidString: "13131313-1313-1313-1313-131313131313")!,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      chunkPlanVersion: GenerationChunkPlan.currentVersion,
      chunkCount: 1,
      totalSteps: 4,
      createdAt: source.meeting.createdAt,
      updatedAt: source.meeting.createdAt,
      state: .pending
    )
    try await jobs.create(job)
    let provider = RecordingGenerationProvider(result: .success("恢复后的纪要。"))
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: GenerationAssetsStub(source: source.transcript),
      profiles: ExecutionProfilesStub(profile: source.execution),
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )

    try await workflow.reconcile(
      in: MeetingLibrarySnapshot(
        directory: source.directory,
        meetings: [source.meeting],
        diagnosticCount: 0
      )
    )

    #expect(await jobs.load(job.id)?.job.state == .completed)
    #expect(provider.recordedRequests().count == 1)
  }

  @Test("Resumes from a persisted summary step without repeating the model request")
  func resumesFromCheckpoint() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let assets = GenerationAssetsStub(source: source.transcript)
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("不应再次请求。"))
    let jobID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    var job = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .publishing,
      progress: 70,
      completedStepCount: 1
    )
    let step = GenerationStep(
      id: "\(jobID.uuidString)/v1/summary/0/\(source.transcript.revision.contentFingerprint)",
      jobID: jobID,
      kind: .summary,
      index: 0,
      inputFingerprint: source.transcript.revision.contentFingerprint,
      output: "持久化的摘要。",
      progress: 70,
      completedAt: createdAt
    )
    try await jobs.create(job)
    job.updatedAt = createdAt.addingTimeInterval(1)
    try await jobs.saveCheckpoint(job, step: step)
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider
    )

    let snapshot = try await workflow.resume(
      jobID,
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.job.progress == 100)
    #expect(snapshot.completedSteps == [step])
    #expect(provider.recordedRequests().isEmpty)
    #expect(await assets.publishCount == 1)
    #expect(await assets.publishedMarkdown?.contains("持久化的摘要。") == true)
  }

  @Test("A malformed summary checkpoint is regenerated before publication")
  func malformedCheckpointIsRegenerated() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let assets = GenerationAssetsStub(source: source.transcript)
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("重新生成的摘要。"))
    let jobID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    var job = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .publishing,
      progress: 70,
      completedStepCount: 1
    )
    let malformedStep = GenerationStep(
      id: "corrupt-checkpoint",
      jobID: jobID,
      kind: .summary,
      index: 0,
      inputFingerprint: source.transcript.revision.contentFingerprint,
      output: "   ",
      progress: 70,
      completedAt: createdAt
    )
    try await jobs.create(job)
    job.updatedAt = createdAt.addingTimeInterval(1)
    try await jobs.saveCheckpoint(job, step: malformedStep)
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider
    )

    let snapshot = try await workflow.resume(
      jobID,
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(provider.recordedRequests().count == 1)
    #expect(await assets.publishedMarkdown?.contains("重新生成的摘要。") == true)
    #expect(!snapshot.completedSteps.contains(malformedStep))
  }

  @Test("A changed transcript pauses the job and never publishes a stale candidate")
  func sourceChangePausesBeforePublication() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let assets = GenerationAssetsStub(source: source.transcript)
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(
      result: .failure(AIProviderError.networkUnavailable)
    )
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      retryDelayScale: 0,
      jitter: { _ in 0 }
    )
    let paused = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )
    await assets.replaceSource(source.changedTranscript)

    let resumed = try await workflow.resume(
      paused.job.id,
      in: source.directory,
      meeting: source.meeting
    )

    #expect(resumed.job.state == .paused)
    #expect(resumed.job.pauseReason == .sourceChanged)
    #expect(await assets.publishCount == 0)
  }

  @Test("Concurrent resume calls share one in-flight generation")
  func concurrentResumeDoesNotDuplicateProviderRequest() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let assets = GenerationAssetsStub(source: source.transcript)
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = BlockingGenerationProvider()
    let jobID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let job = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .pending,
      pauseReason: .unavailable
    )
    try await jobs.create(job)
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider
    )

    let first = Task {
      try await workflow.resume(
        jobID,
        in: source.directory,
        meeting: source.meeting
      )
    }
    await provider.waitUntilStarted()
    let second = Task {
      try await workflow.resume(
        jobID,
        in: source.directory,
        meeting: source.meeting
      )
    }
    let secondSnapshot = try await second.value

    #expect(secondSnapshot.job.state == .running)
    #expect(provider.requestCount == 1)

    await workflow.cancel(jobID)
    #expect(await provider.waitUntilTerminated())
    provider.finish()
    let firstSnapshot = try await first.value

    #expect(firstSnapshot.job.state == .paused)
    #expect(firstSnapshot.job.pauseReason == .cancelled)
    #expect(await assets.publishCount == 0)
  }

  @Test("Usage reconciliation preserves a registration awaiting job creation")
  func usageReconciliationPreservesPendingRegistration() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let profiles = BlockingRegisterProfiles(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("待发布摘要。"))
    let jobID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: GenerationAssetsStub(source: source.transcript),
      profiles: profiles,
      provider: provider,
      makeJobID: { jobID }
    )

    let startTask = Task {
      try await workflow.start(
        in: source.directory,
        meeting: source.meeting
      )
    }
    await profiles.waitUntilRegistrationStarted()
    _ = try await workflow.load(meetingID: source.meeting.id)

    let pendingReference = ModelProfileTaskReference(rawValue: jobID)
    #expect(
      await profiles.reconciledReferences.contains { references in
        references.contains(pendingReference)
      }
    )

    await profiles.finishRegistration()
    let snapshot = try await startTask.value
    #expect(snapshot.job.state == .completed)
  }

  @Test("Cancelling a checkpoint resume before publication remains recoverable")
  func callerCancellationDuringCheckpointResumeIsRecoverable() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let assets = BlockingTranscriptAssets(source: source.transcript)
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("不应请求。"))
    let jobID = UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let job = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .publishing,
      progress: 70,
      completedStepCount: 1
    )
    let step = GenerationStep(
      id: "\(jobID.uuidString)/v1/summary/0/\(source.transcript.revision.contentFingerprint)",
      jobID: jobID,
      kind: .summary,
      index: 0,
      inputFingerprint: source.transcript.revision.contentFingerprint,
      output: "持久化摘要。",
      progress: 70,
      completedAt: createdAt
    )
    try await jobs.create(job)
    try await jobs.saveCheckpoint(job, step: step)
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider
    )

    let resumeTask = Task {
      try await workflow.resume(
        jobID,
        in: source.directory,
        meeting: source.meeting
      )
    }
    await assets.waitUntilLoadStarted()
    resumeTask.cancel()
    await assets.finishLoad()
    let snapshot = try await resumeTask.value

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .cancelled)
    #expect(provider.recordedRequests().isEmpty)
    #expect(await assets.publishCount == 0)
  }

  @Test("Cancellation during resume loading remains recoverable")
  func cancellationDuringResumeLoadingIsNotCleared() async throws {
    let source = try GenerationTestSource()
    let jobs = InMemoryGenerationJobStore()
    let assets = BlockingTranscriptAssets(source: source.transcript)
    let profiles = ExecutionProfilesStub(profile: source.execution)
    let provider = RecordingGenerationProvider(result: .success("不应请求。"))
    let jobID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let job = GenerationJob(
      id: jobID,
      meetingID: source.meeting.id,
      transcriptRevisionID: source.transcript.revision.id,
      transcriptFingerprint: source.transcript.revision.contentFingerprint,
      modelProfile: source.execution.snapshot,
      createdAt: createdAt,
      updatedAt: createdAt,
      state: .paused,
      stage: .pending,
      pauseReason: .unavailable
    )
    try await jobs.create(job)
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider
    )

    let resumeTask = Task {
      try await workflow.resume(
        jobID,
        in: source.directory,
        meeting: source.meeting
      )
    }
    await assets.waitUntilLoadStarted()
    await workflow.cancel(jobID)
    await assets.finishLoad()
    let snapshot = try await resumeTask.value

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .cancelled)
    #expect(provider.recordedRequests().isEmpty)
    #expect(await assets.publishCount == 0)
  }
}

private actor InMemoryGenerationJobStore: GenerationJobStore {
  private var jobs: [UUID: GenerationSnapshot] = [:]

  func create(_ job: GenerationJob) throws {
    guard jobs.values.filter({ $0.job.isActive }).count < 20 else {
      throw GenerationJobStoreError.queueFull
    }
    guard
      jobs.values.allSatisfy({
        $0.job.meetingID != job.meetingID || !$0.job.isActive
      })
    else {
      throw GenerationJobStoreError.conflict
    }
    jobs[job.id] = GenerationSnapshot(job: job)
  }

  func load(_ id: UUID) -> GenerationSnapshot? {
    jobs[id]
  }

  func activeJob(for meetingID: MeetingID) -> GenerationSnapshot? {
    jobs.values.first {
      $0.job.meetingID == meetingID && $0.job.isActive
    }
  }

  func replaceActive(_ jobID: UUID, with job: GenerationJob) throws {
    guard
      let state = jobs[jobID]?.job.state,
      state == .pending || state == .paused
    else {
      throw GenerationJobStoreError.conflict
    }
    guard jobs.values.filter({ $0.job.isActive && $0.job.id != jobID }).count < 20 else {
      throw GenerationJobStoreError.queueFull
    }
    var superseded = jobs[jobID]!.job
    superseded.state = .superseded
    superseded.stage = .completed
    superseded.completedAt = job.updatedAt
    superseded.updatedAt = job.updatedAt
    jobs[jobID] = GenerationSnapshot(job: superseded, completedSteps: jobs[jobID]!.completedSteps)
    jobs[job.id] = GenerationSnapshot(job: job)
  }

  func latestJob(for meetingID: MeetingID) -> GenerationSnapshot? {
    jobs.values
      .filter { $0.job.meetingID == meetingID }
      .max {
        ($0.job.generationNumber, $0.job.updatedAt)
          < ($1.job.generationNumber, $1.job.updatedAt)
      }
  }

  func resumableJobs() -> [GenerationSnapshot] {
    jobs.values
      .filter { $0.job.isActive }
      .sorted {
        if $0.job.createdAt != $1.job.createdAt {
          return $0.job.createdAt < $1.job.createdAt
        }
        return $0.job.id.uuidString < $1.job.id.uuidString
      }
  }

  func saveCheckpoint(_ job: GenerationJob, step: GenerationStep?) throws {
    guard let previous = jobs[job.id] else {
      throw GenerationJobStoreError.notFound
    }
    guard job.progress >= previous.job.progress else {
      throw GenerationJobStoreError.invalidData
    }
    var steps = previous.completedSteps
    if let step {
      steps.removeAll { $0.kind == step.kind && $0.index == step.index }
      steps.append(step)
      steps.sort { $0.index < $1.index }
    }
    jobs[job.id] = GenerationSnapshot(job: job, completedSteps: steps)
  }

  func delete(_ id: UUID) {
    jobs[id] = nil
  }
}

private actor GenerationJobRegistrationCollector {
  private(set) var ids: [UUID] = []

  func append(_ job: GenerationJob) {
    ids.append(job.id)
  }
}

private actor GenerationAssetsStub: GenerationFileAccess {
  private(set) var source: GenerationTranscriptSource
  private(set) var existingMinutes: String?
  private(set) var publishedMarkdown: String?
  private(set) var publishCount = 0

  init(
    source: GenerationTranscriptSource,
    existingMinutes: String? = nil,
    publicationError: GenerationFileError? = nil
  ) {
    self.source = source
    self.existingMinutes = existingMinutes
    self.publicationError = publicationError
  }

  private let publicationError: GenerationFileError?

  func loadTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) -> GenerationTranscriptSource {
    source
  }

  func publishMinutes(
    _ markdown: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) throws {
    guard
      source.revision.id == expectedTranscriptRevisionID,
      source.revision.contentFingerprint == expectedTranscriptFingerprint
    else {
      throw GenerationFileError.sourceChanged
    }
    if let publicationError {
      throw publicationError
    }
    publishCount += 1
    publishedMarkdown = markdown
    existingMinutes = markdown
  }

  func replaceSource(_ source: GenerationTranscriptSource) {
    self.source = source
  }
}

private actor VersionedMinutesAssets: GenerationFileAccess {
  let source: GenerationTranscriptSource
  private(set) var minutes: String?

  init(source: GenerationTranscriptSource) {
    self.source = source
  }

  func loadTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) -> GenerationTranscriptSource {
    source
  }

  func loadMinutesSnapshot(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) -> GenerationMinutesSnapshot? {
    guard let minutes else {
      return nil
    }
    return GenerationMinutesSnapshot(
      contentFingerprint: GenerationInputFingerprint.make(minutes)
    )
  }

  func publishMinutes(
    _ markdown: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) throws {
    guard
      source.revision.id == expectedTranscriptRevisionID,
      source.revision.contentFingerprint == expectedTranscriptFingerprint
    else {
      throw GenerationFileError.sourceChanged
    }
    minutes = markdown
  }

  func replaceMinutes(_ markdown: String) {
    minutes = markdown
  }
}

private actor BlockingPublicationAssets: GenerationFileAccess {
  private let source: GenerationTranscriptSource
  private var publicationContinuation: CheckedContinuation<Void, Never>?
  private var publicationStarted = false

  init(source: GenerationTranscriptSource) {
    self.source = source
  }

  func loadTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) -> GenerationTranscriptSource {
    source
  }

  func publishMinutes(
    _ markdown: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) async throws {
    guard
      source.revision.id == expectedTranscriptRevisionID,
      source.revision.contentFingerprint == expectedTranscriptFingerprint
    else {
      throw GenerationFileError.sourceChanged
    }
    publicationStarted = true
    await withCheckedContinuation { continuation in
      publicationContinuation = continuation
    }
  }

  func waitUntilPublicationStarted() async {
    while !publicationStarted {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func finishPublication() {
    let continuation = publicationContinuation
    publicationContinuation = nil
    continuation?.resume()
  }
}

private actor BlockingTranscriptAssets: GenerationFileAccess {
  private let source: GenerationTranscriptSource
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private var loadStarted = false
  private(set) var publishCount = 0

  init(source: GenerationTranscriptSource) {
    self.source = source
  }

  func loadTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async -> GenerationTranscriptSource {
    loadStarted = true
    await withCheckedContinuation { continuation in
      loadContinuation = continuation
    }
    return source
  }

  func publishMinutes(
    _ markdown: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) throws {
    guard
      source.revision.id == expectedTranscriptRevisionID,
      source.revision.contentFingerprint == expectedTranscriptFingerprint
    else {
      throw GenerationFileError.sourceChanged
    }
    publishCount += 1
  }

  func waitUntilLoadStarted() async {
    while !loadStarted {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func finishLoad() {
    let continuation = loadContinuation
    loadContinuation = nil
    continuation?.resume()
  }
}

private actor ExecutionProfilesStub: ModelProfileExecutionAccess {
  let profile: ModelExecutionProfile
  private(set) var registered: [ModelProfileTaskReference] = []
  private(set) var finished: [ModelProfileTaskReference] = []

  init(profile: ModelExecutionProfile) {
    self.profile = profile
  }

  func currentExecutionProfile() -> ModelExecutionProfile {
    profile
  }

  func executionProfile(
    for snapshot: ModelProfileSnapshot
  ) throws -> ModelExecutionProfile {
    guard snapshot == profile.snapshot else {
      throw ModelCredentialError.notFound
    }
    return profile
  }

  func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) {
    registered.append(task)
  }

  func finishTask(_ task: ModelProfileTaskReference) {
    finished.append(task)
  }

  func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) {}
}

private actor SwitchingExecutionProfiles: ModelProfileExecutionAccess {
  private var current: ModelExecutionProfile
  private var profiles: [ModelProfileID: ModelExecutionProfile]

  init(initial: ModelExecutionProfile) {
    current = initial
    profiles = [initial.snapshot.profileID: initial]
  }

  func select(_ profile: ModelExecutionProfile) {
    current = profile
    profiles[profile.snapshot.profileID] = profile
  }

  func currentExecutionProfile() -> ModelExecutionProfile {
    current
  }

  func executionProfile(
    for snapshot: ModelProfileSnapshot
  ) throws -> ModelExecutionProfile {
    guard let profile = profiles[snapshot.profileID], profile.snapshot == snapshot else {
      throw ModelCredentialError.notFound
    }
    return profile
  }

  func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) {}

  func finishTask(_ task: ModelProfileTaskReference) {}

  func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) {}
}

private actor BlockingRegisterProfiles: ModelProfileExecutionAccess {
  let profile: ModelExecutionProfile
  private var registrationContinuation: CheckedContinuation<Void, Never>?
  private var registrationStarted = false
  private(set) var reconciledReferences: [Set<ModelProfileTaskReference>] = []

  init(profile: ModelExecutionProfile) {
    self.profile = profile
  }

  func currentExecutionProfile() -> ModelExecutionProfile {
    profile
  }

  func executionProfile(
    for snapshot: ModelProfileSnapshot
  ) throws -> ModelExecutionProfile {
    guard snapshot == profile.snapshot else {
      throw ModelCredentialError.notFound
    }
    return profile
  }

  func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) async {
    registrationStarted = true
    await withCheckedContinuation { continuation in
      registrationContinuation = continuation
    }
  }

  func finishTask(_ task: ModelProfileTaskReference) {}

  func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) {
    reconciledReferences.append(taskReferences)
  }

  func waitUntilRegistrationStarted() async {
    while !registrationStarted {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func finishRegistration() {
    let continuation = registrationContinuation
    registrationContinuation = nil
    continuation?.resume()
  }
}

private final class RecordingGenerationProvider: AIProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<String, AIProviderError>
  private(set) var requests: [AIRequest] = []

  init(result: Result<String, AIProviderError>) {
    self.result = result
  }

  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    ModelCapability(providerDomain: profile.baseURL.host ?? "", representativeContent: true)
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    lock.withLock {
      requests.append(request)
    }
    return AsyncThrowingStream { continuation in
      switch result {
      case .success(let output):
        continuation.yield(.textDelta(output))
        continuation.yield(.completed)
        continuation.finish()
      case .failure(let error):
        continuation.finish(throwing: error)
      }
    }
  }

  func recordedRequests() -> [AIRequest] {
    lock.withLock { requests }
  }
}

private final class SequencedGenerationProvider: AIProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<String, AIProviderError>]
  private(set) var requestCount = 0

  init(results: [Result<String, AIProviderError>]) {
    self.results = results
  }

  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    ModelCapability(providerDomain: profile.baseURL.host ?? "", representativeContent: true)
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    let result = lock.withLock {
      requestCount += 1
      return results.isEmpty ? .success("默认输出") : results.removeFirst()
    }
    return AsyncThrowingStream { continuation in
      switch result {
      case .success(let output):
        continuation.yield(.textDelta(output))
        continuation.yield(.completed)
        continuation.finish()
      case .failure(let error):
        continuation.finish(throwing: error)
      }
    }
  }
}

private final class GenerationIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var ids: [UUID]

  init(ids: [UUID]) {
    self.ids = ids
  }

  func next() -> UUID {
    lock.withLock { ids.removeFirst() }
  }
}

private final class BlockingGenerationProvider: AIProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<AIEvent, Error>.Continuation?
  private var terminated = false
  private var requests = 0

  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    ModelCapability(providerDomain: profile.baseURL.host ?? "", representativeContent: true)
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.onTermination = { @Sendable [weak self] _ in
        self?.lock.withLock {
          self?.terminated = true
          self?.continuation = nil
        }
      }
      lock.withLock {
        self.terminated = false
        self.continuation = continuation
        self.requests += 1
      }
    }
  }

  func waitUntilStarted() async {
    while lock.withLock({ continuation == nil }) {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func waitUntilRequestCount(_ expected: Int) async {
    while lock.withLock({ requests < expected }) {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  func finish() {
    let activeContinuation = lock.withLock {
      let activeContinuation = continuation
      continuation = nil
      return activeContinuation
    }
    activeContinuation?.finish()
  }

  func waitUntilTerminated() async -> Bool {
    for _ in 0..<200 {
      if lock.withLock({ terminated }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  var requestCount: Int {
    lock.withLock { requests }
  }
}

private struct GenerationTestSource {
  let directory: AuthoritativeDirectory
  let meeting: MeetingIndexEntry
  let meetingWithMinutes: MeetingIndexEntry
  let transcript: GenerationTranscriptSource
  let changedTranscript: GenerationTranscriptSource
  let execution: ModelExecutionProfile
  let alternateExecution: ModelExecutionProfile

  init() throws {
    let meetingID = MeetingID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
    directory = AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "directory"),
      displayName: "Meetings",
      kind: .userSelected
    )
    meeting = MeetingIndexEntry(
      id: meetingID,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: "meeting-20270115-080000",
      assets: [.recording, .transcript],
      durationSeconds: 20
    )
    meetingWithMinutes = MeetingIndexEntry(
      id: meetingID,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: "meeting-20270115-080000",
      assets: [.recording, .transcript, .minutes],
      durationSeconds: 20
    )
    let timeline = TranscriptTimeline(
      audioDurationSeconds: 20,
      segments: [
        TranscriptSegment(
          id: "segment-1",
          startSeconds: 0,
          endSeconds: 10,
          text: "第一段"
        ),
        TranscriptSegment(
          id: "segment-2",
          startSeconds: 10,
          endSeconds: 20,
          text: "第二段"
        ),
      ]
    )
    let changedTimeline = TranscriptTimeline(
      audioDurationSeconds: 20,
      segments: [
        TranscriptSegment(
          id: "segment-1",
          startSeconds: 0,
          endSeconds: 10,
          text: "已被修改"
        )
      ]
    )
    transcript = GenerationTranscriptSource(
      revision: TranscriptRevision(
        meetingID: meetingID,
        localeIdentifier: "zh-CN",
        timeline: timeline
      )
    )
    changedTranscript = GenerationTranscriptSource(
      revision: TranscriptRevision(
        meetingID: meetingID,
        localeIdentifier: "zh-CN",
        timeline: changedTimeline
      )
    )
    let profile = ModelProfileSnapshot(
      profileID: ModelProfileID(
        rawValue: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!),
      baseURL: URL(string: "https://api.example.com/v1")!,
      model: "minutes-model",
      parameters: ModelGenerationParameters(),
      credentialReference: ModelCredentialReference(
        rawValue: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!)
    )
    execution = ModelExecutionProfile(snapshot: profile, apiKey: "secret")
    let alternateProfile = ModelProfileSnapshot(
      profileID: ModelProfileID(
        rawValue: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
      ),
      baseURL: URL(string: "https://alternate.example.com/v1")!,
      model: "alternate-minutes-model",
      parameters: ModelGenerationParameters(temperature: 0.2),
      credentialReference: ModelCredentialReference(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
      )
    )
    alternateExecution = ModelExecutionProfile(
      snapshot: alternateProfile,
      apiKey: "alternate-secret"
    )
  }
}
