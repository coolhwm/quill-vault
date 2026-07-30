import Domain

public actor RetryingRecordingUseCase: RecordingUseCase {
  public typealias Factory = @Sendable () async throws -> any RecordingUseCase

  private let factory: Factory
  private var resolvedUseCase: (any RecordingUseCase)?
  private var initializationTask: Task<any RecordingUseCase, Error>?
  private var initializationGeneration = 0

  public init(factory: @escaping Factory) {
    self.factory = factory
  }

  public func restore() async throws -> RecordingSnapshot? {
    try await resolve().restore()
  }

  public func acknowledgeRecordingNotice() async throws {
    try await resolve().acknowledgeRecordingNotice()
  }

  public func start() async throws -> RecordingSnapshot {
    try await resolve().start()
  }

  public func liveTranscript(
    meetingID: MeetingID
  ) async -> AsyncStream<LiveTranscriptSnapshot> {
    do {
      return try await resolve().liveTranscript(meetingID: meetingID)
    } catch {
      return AsyncStream { $0.finish() }
    }
  }

  public func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent> {
    do {
      return try await resolve().captureEvents(meetingID: meetingID)
    } catch {
      return AsyncStream { $0.finish() }
    }
  }

  public func catchUpLiveTranscript() async {
    do {
      try await resolve().catchUpLiveTranscript()
    } catch {
      // Foreground catch-up is best effort. The durable finalization job remains
      // authoritative and will retry after initialization becomes available.
    }
  }

  public func stop() async throws -> RecordingCompletion {
    try await resolve().stop()
  }

  public func finishInterrupted() async throws -> RecordingCompletion {
    try await resolve().finishInterrupted()
  }

  public func resumeInterrupted() async throws -> RecordingSnapshot {
    try await resolve().resumeInterrupted()
  }

  public func recoverPendingTranscriptions() async throws
    -> [TranscriptionRecoveryResult]
  {
    try await resolve().recoverPendingTranscriptions()
  }

  private func resolve() async throws -> any RecordingUseCase {
    if let resolvedUseCase {
      return resolvedUseCase
    }
    if let initializationTask {
      return try await initializationTask.value
    }

    initializationGeneration += 1
    let generation = initializationGeneration
    let factory = self.factory
    let task = Task {
      try await factory()
    }
    initializationTask = task

    do {
      let useCase = try await task.value
      if generation == initializationGeneration {
        resolvedUseCase = useCase
        initializationTask = nil
      }
      return useCase
    } catch {
      if generation == initializationGeneration {
        initializationTask = nil
      }
      throw error
    }
  }
}
