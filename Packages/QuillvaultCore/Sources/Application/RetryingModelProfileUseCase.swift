import Domain

public actor RetryingModelProfileUseCase:
  ModelProfileUseCase, ModelProfileExecutionAccess
{
  public typealias Builder =
    @Sendable () throws -> any ModelProfileUseCase

  private let builder: Builder
  private var resolved: (any ModelProfileUseCase)?

  public init(builder: @escaping Builder) {
    self.builder = builder
  }

  public func load() async throws -> ModelProfileCollection {
    try await resolve().load()
  }

  public func save(
    _ draft: ModelProfileDraft
  ) async throws -> ModelProfile {
    try await resolve().save(draft)
  }

  public func select(_ id: ModelProfileID) async throws {
    try await resolve().select(id)
  }

  public func test(
    _ id: ModelProfileID
  ) async throws -> ModelCapability {
    try await resolve().test(id)
  }

  public func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async throws {
    try await resolve().setAutomaticGeneration(
      enabled: enabled,
      disclosureAcknowledged: disclosureAcknowledged
    )
  }

  public func deletionImpact(
    _ id: ModelProfileID
  ) async throws -> ModelProfileDeletionImpact {
    try await resolve().deletionImpact(id)
  }

  public func delete(
    _ id: ModelProfileID,
    confirmed: Bool
  ) async throws {
    try await resolve().delete(id, confirmed: confirmed)
  }

  public func currentExecutionProfile() async throws
    -> ModelExecutionProfile
  {
    guard let access = try resolve() as? any ModelProfileExecutionAccess else {
      throw ModelProfileWorkflowError.profileNotUsable
    }
    return try await access.currentExecutionProfile()
  }

  public func executionProfile(
    for snapshot: ModelProfileSnapshot
  ) async throws -> ModelExecutionProfile {
    guard let access = try resolve() as? any ModelProfileExecutionAccess else {
      throw ModelProfileWorkflowError.profileNotUsable
    }
    return try await access.executionProfile(for: snapshot)
  }

  public func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) async throws {
    guard let access = try resolve() as? any ModelProfileExecutionAccess else {
      return
    }
    try await access.registerUnfinishedTask(task, profileID: profileID)
  }

  public func finishTask(_ task: ModelProfileTaskReference) async throws {
    guard let access = try resolve() as? any ModelProfileExecutionAccess else {
      return
    }
    try await access.finishTask(task)
  }

  public func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) async throws {
    guard let access = try resolve() as? any ModelProfileExecutionAccess else {
      return
    }
    try await access.reconcileUnfinishedTasks(keeping: taskReferences)
  }

  private func resolve() throws -> any ModelProfileUseCase {
    if let resolved {
      return resolved
    }
    let created = try builder()
    resolved = created
    return created
  }
}
