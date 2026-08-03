import Domain
import Foundation
import PersistenceGRDB
import Testing

@Suite("GRDB generation job store")
struct GRDBGenerationJobStoreTests {
  @Test("Persists a generation job and checkpoint across reopening")
  func persistenceAcrossReopen() async throws {
    let databaseURL = temporaryGenerationDatabaseURL()
    let source = GenerationStoreFixture()
    let step = source.step
    do {
      let store = try GRDBGenerationJobStore.open(at: databaseURL)
      try await store.create(source.job)
      try await store.saveCheckpoint(source.job, step: step)
      try await store.close()
    }

    let reopened = try GRDBGenerationJobStore.open(at: databaseURL)
    let snapshot = try await reopened.load(source.job.id)
    #expect(snapshot?.job == source.job)
    #expect(snapshot?.completedSteps == [step])
    try await reopened.close()
    removeDatabase(at: databaseURL)
  }

  @Test("Allows only one unfinished generation job per meeting")
  func activeMeetingConflict() async throws {
    let store = try GRDBGenerationJobStore.open(
      at: temporaryGenerationDatabaseURL()
    )
    let source = GenerationStoreFixture()
    try await store.create(source.job)
    await #expect(throws: GenerationJobStoreError.conflict) {
      try await store.create(
        GenerationJob(
          id: UUID(),
          meetingID: source.job.meetingID,
          transcriptRevisionID: source.job.transcriptRevisionID,
          transcriptFingerprint: source.job.transcriptFingerprint,
          modelProfile: source.job.modelProfile,
          createdAt: source.job.createdAt,
          updatedAt: source.job.updatedAt
        )
      )
    }
    try await store.close()
  }

  @Test("Rejects progress regression while preserving the last durable checkpoint")
  func progressCannotRegress() async throws {
    let databaseURL = temporaryGenerationDatabaseURL()
    let store = try GRDBGenerationJobStore.open(at: databaseURL)
    let source = GenerationStoreFixture()
    var progressed = source.job
    progressed.progress = 70
    progressed.completedStepCount = 1
    progressed.stage = .publishing
    let step = source.step
    try await store.create(source.job)
    try await store.saveCheckpoint(progressed, step: step)

    var regressed = progressed
    regressed.progress = 20
    await #expect(throws: GenerationJobStoreError.invalidData) {
      try await store.saveCheckpoint(regressed, step: nil)
    }

    let snapshot = try await store.load(source.job.id)
    #expect(snapshot?.job.progress == 70)
    #expect(snapshot?.completedSteps == [step])
    try await store.close()
    removeDatabase(at: databaseURL)
  }

  @Test("Clamps an unfinished job below publication completion after reload")
  func unfinishedProgressCannotLookCompleted() async throws {
    let databaseURL = temporaryGenerationDatabaseURL()
    let store = try GRDBGenerationJobStore.open(at: databaseURL)
    let source = GenerationStoreFixture()
    try await store.create(source.job)

    var corrupted = source.job
    corrupted.state = .running
    corrupted.stage = .publishing
    corrupted.progress = 100
    try await store.saveCheckpoint(corrupted, step: nil)

    let snapshot = try await store.load(source.job.id)
    #expect(snapshot?.job.state == .running)
    #expect(snapshot?.job.progress == 99)

    try await store.close()
    removeDatabase(at: databaseURL)
  }

  @Test("Caps the durable generation queue at twenty unfinished jobs")
  func queueCapacityIsBounded() async throws {
    let databaseURL = temporaryGenerationDatabaseURL()
    let store = try GRDBGenerationJobStore.open(at: databaseURL)
    let source = GenerationStoreFixture()

    for index in 0..<20 {
      try await store.create(
        GenerationJob(
          id: UUID(),
          meetingID: MeetingID(rawValue: UUID()),
          transcriptRevisionID: source.job.transcriptRevisionID,
          transcriptFingerprint: source.job.transcriptFingerprint,
          modelProfile: source.job.modelProfile,
          createdAt: source.job.createdAt.addingTimeInterval(Double(index)),
          updatedAt: source.job.updatedAt.addingTimeInterval(Double(index))
        )
      )
    }

    await #expect(throws: GenerationJobStoreError.queueFull) {
      try await store.create(
        GenerationJob(
          id: UUID(),
          meetingID: MeetingID(rawValue: UUID()),
          transcriptRevisionID: source.job.transcriptRevisionID,
          transcriptFingerprint: source.job.transcriptFingerprint,
          modelProfile: source.job.modelProfile,
          createdAt: source.job.createdAt,
          updatedAt: source.job.updatedAt
        )
      )
    }
    #expect((try await store.resumableJobs()).count == 20)
    try await store.close()
    removeDatabase(at: databaseURL)
  }
}

private struct GenerationStoreFixture {
  let job: GenerationJob
  let step: GenerationStep

  init() {
    let meetingID = MeetingID(
      rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    let profile = ModelProfileSnapshot(
      profileID: ModelProfileID(
        rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
      ),
      baseURL: URL(string: "https://api.example.com/v1")!,
      model: "minutes-model",
      parameters: ModelGenerationParameters(),
      credentialReference: ModelCredentialReference(
        rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
      )
    )
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    job = GenerationJob(
      id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
      meetingID: meetingID,
      transcriptRevisionID: "revision-1",
      transcriptFingerprint: "fingerprint-1",
      modelProfile: profile,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    step = GenerationStep(
      id: "step-1",
      jobID: job.id,
      kind: .summary,
      index: 0,
      inputFingerprint: job.transcriptFingerprint,
      output: "摘要",
      progress: 70,
      completedAt: createdAt
    )
  }
}

private func temporaryGenerationDatabaseURL() -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "generation-store-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try! FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return directory.appending(path: "generation.sqlite")
}

private func removeDatabase(at url: URL) {
  try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
