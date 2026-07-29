import Domain

public actor RetryingMeetingLibraryUseCase: MeetingLibraryUseCase {
  public typealias Factory =
    @Sendable () async throws -> any MeetingLibraryUseCase

  private let factory: Factory
  private var resolvedLibrary: (any MeetingLibraryUseCase)?
  private var initializationTask: Task<any MeetingLibraryUseCase, Error>?
  private var initializationGeneration = 0

  public init(factory: @escaping Factory) {
    self.factory = factory
  }

  public func restore() async throws -> MeetingLibrarySnapshot {
    try await resolve().restore()
  }

  public func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    try await resolve().select(selection)
  }

  public func rebuild() async throws -> MeetingLibrarySnapshot {
    try await resolve().rebuild()
  }

  private func resolve() async throws -> any MeetingLibraryUseCase {
    if let resolvedLibrary {
      return resolvedLibrary
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
      let library = try await task.value
      if generation == initializationGeneration {
        resolvedLibrary = library
        initializationTask = nil
      }
      return library
    } catch {
      if generation == initializationGeneration {
        initializationTask = nil
      }
      throw error
    }
  }
}
