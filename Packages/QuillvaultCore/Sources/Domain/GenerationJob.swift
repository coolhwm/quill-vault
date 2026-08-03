import Foundation

public enum GenerationJobState: String, Codable, CaseIterable, Sendable {
  case pending
  case running
  case paused
  case completed
  case superseded
}

public enum GenerationStage: String, Codable, CaseIterable, Sendable {
  case pending
  case summarizing
  case synthesizing
  case normalizing
  case publishing
  case completed
}

public enum GenerationPauseReason: String, Codable, CaseIterable, Sendable {
  case cancelled
  case credentialsUnavailable
  case authenticationRequired
  case modelUnavailable
  case rateLimited
  case serviceUnavailable
  case retryableRequest
  case networkUnavailable
  case invalidResponse
  case retryExhausted
  case requestTooLarge
  case sourceChanged
  case publicationFailed
  case externalMinutesChanged
  case unavailable
}

public enum GenerationStepKind: String, Codable, CaseIterable, Sendable {
  case chunkSummary
  case synthesis
  case normalization
  case publication
  // Kept for jobs created by the first MVP generation implementation.
  case summary
}

public struct GenerationJob: Codable, Equatable, Sendable {
  public let id: UUID
  public let meetingID: MeetingID
  public let transcriptRevisionID: String
  public let transcriptFingerprint: String
  public let modelProfile: ModelProfileSnapshot
  public let promptVersion: String
  public let schemaVersion: String
  public let chunkPlanVersion: String
  public let generationNumber: Int
  public let chunkCount: Int
  public let totalSteps: Int
  public let createdAt: Date
  public var updatedAt: Date
  public var completedAt: Date?
  public var state: GenerationJobState
  public var stage: GenerationStage
  public var progress: Int
  public var completedStepCount: Int
  public var completedChunkCount: Int
  public var retryAttempt: Int
  public var nextRetryAt: Date?
  public var pauseReason: GenerationPauseReason?
  public var publishedMinutesFingerprint: String?

  public init(
    id: UUID,
    meetingID: MeetingID,
    transcriptRevisionID: String,
    transcriptFingerprint: String,
    modelProfile: ModelProfileSnapshot,
    promptVersion: String = "v1",
    schemaVersion: String = "v1",
    chunkPlanVersion: String = "v1",
    generationNumber: Int = 1,
    chunkCount: Int = 1,
    totalSteps: Int = 1,
    createdAt: Date,
    updatedAt: Date,
    completedAt: Date? = nil,
    state: GenerationJobState = .pending,
    stage: GenerationStage = .pending,
    progress: Int = 0,
    completedStepCount: Int = 0,
    completedChunkCount: Int = 0,
    retryAttempt: Int = 0,
    nextRetryAt: Date? = nil,
    pauseReason: GenerationPauseReason? = nil,
    publishedMinutesFingerprint: String? = nil
  ) {
    self.id = id
    self.meetingID = meetingID
    self.transcriptRevisionID = transcriptRevisionID
    self.transcriptFingerprint = transcriptFingerprint
    self.modelProfile = modelProfile
    self.promptVersion = promptVersion
    self.schemaVersion = schemaVersion
    self.chunkPlanVersion = chunkPlanVersion
    self.generationNumber = generationNumber
    self.chunkCount = max(1, chunkCount)
    self.totalSteps = max(1, totalSteps)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
    self.state = state
    self.stage = stage
    let maximumProgress = state == .completed ? 100 : 99
    self.progress = min(max(progress, 0), maximumProgress)
    self.completedStepCount = min(
      max(completedStepCount, 0),
      max(1, totalSteps)
    )
    self.completedChunkCount = min(
      max(completedChunkCount, 0),
      max(1, chunkCount)
    )
    self.retryAttempt = max(0, retryAttempt)
    self.nextRetryAt = nextRetryAt
    self.pauseReason = pauseReason
    self.publishedMinutesFingerprint = publishedMinutesFingerprint
  }

  public var taskReference: ModelProfileTaskReference {
    ModelProfileTaskReference(rawValue: id)
  }

  public var isActive: Bool {
    switch state {
    case .pending, .running, .paused:
      return true
    case .completed, .superseded:
      return false
    }
  }
}

public struct GenerationStep: Codable, Equatable, Sendable {
  public let id: String
  public let jobID: UUID
  public let kind: GenerationStepKind
  public let index: Int
  public let inputFingerprint: String
  public let output: String
  public let progress: Int
  public let completedAt: Date

  public init(
    id: String,
    jobID: UUID,
    kind: GenerationStepKind,
    index: Int,
    inputFingerprint: String,
    output: String,
    progress: Int,
    completedAt: Date
  ) {
    self.id = id
    self.jobID = jobID
    self.kind = kind
    self.index = index
    self.inputFingerprint = inputFingerprint
    self.output = output
    self.progress = min(max(progress, 0), 99)
    self.completedAt = completedAt
  }
}

public struct GenerationSnapshot: Equatable, Sendable {
  public let job: GenerationJob
  public let completedSteps: [GenerationStep]

  public init(
    job: GenerationJob,
    completedSteps: [GenerationStep] = []
  ) {
    self.job = job
    self.completedSteps = completedSteps
  }
}

public enum GenerationJobStoreError: Error, Equatable, Sendable {
  case unavailable
  case conflict
  case queueFull
  case invalidData
  case notFound
}

public protocol GenerationJobStore: Sendable {
  func create(_ job: GenerationJob) async throws
  func load(_ id: UUID) async throws -> GenerationSnapshot?
  func activeJob(for meetingID: MeetingID) async throws -> GenerationSnapshot?
  func latestJob(for meetingID: MeetingID) async throws -> GenerationSnapshot?
  func replaceActive(
    _ jobID: UUID,
    with job: GenerationJob
  ) async throws
  func resumableJobs() async throws -> [GenerationSnapshot]
  func saveCheckpoint(
    _ job: GenerationJob,
    step: GenerationStep?
  ) async throws
  func delete(_ id: UUID) async throws
}

extension GenerationJobStore {
  public func latestJob(for meetingID: MeetingID) async throws -> GenerationSnapshot? {
    let snapshots = try await resumableJobs()

    return
      snapshots
      .filter { $0.job.meetingID == meetingID }
      .max {
        ($0.job.generationNumber, $0.job.updatedAt)
          < ($1.job.generationNumber, $1.job.updatedAt)
      }
  }
}
