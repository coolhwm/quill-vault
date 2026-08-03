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
    let workflow = GenerationWorkflow(
      jobs: jobs,
      assets: assets,
      profiles: profiles,
      provider: provider,
      now: { Date(timeIntervalSince1970: 1_800_000_000) },
      makeJobID: { UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")! }
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .completed)
    #expect(snapshot.job.progress == 100)
    #expect(snapshot.completedSteps.count == 1)
    #expect(await assets.publishedMarkdown?.contains("已确认下一步。") == true)
    let requests = provider.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.userPrompt.contains(source.transcript.promptText) == true)
    #expect(await profiles.registered.count == 1)
    #expect(await profiles.finished.count == 1)
    #expect(await jobs.load(snapshot.job.id)?.job.progress == 100)
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
      provider: provider
    )

    let snapshot = try await workflow.start(
      in: source.directory,
      meeting: source.meeting
    )

    #expect(snapshot.job.state == .paused)
    #expect(snapshot.job.pauseReason == .serviceUnavailable)
    #expect(await assets.publishCount == 0)
    #expect(await assets.existingMinutes == "previous minutes")
    #expect(await profiles.finished.isEmpty)
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
      provider: provider
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
      provider: provider
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
    guard
      jobs.values.allSatisfy({
        $0.job.meetingID != job.meetingID || $0.job.state == .completed
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
      $0.job.meetingID == meetingID && $0.job.state != .completed
    }
  }

  func resumableJobs() -> [GenerationSnapshot] {
    jobs.values.filter { $0.job.state != .completed }
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
    expectedTranscriptFingerprint: String
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
    expectedTranscriptFingerprint: String
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
    expectedTranscriptFingerprint: String
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
  let transcript: GenerationTranscriptSource
  let changedTranscript: GenerationTranscriptSource
  let execution: ModelExecutionProfile

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
  }
}
