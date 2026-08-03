import Domain

public actor RetryingModelProfileUseCase: ModelProfileUseCase {
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

  private func resolve() throws -> any ModelProfileUseCase {
    if let resolved {
      return resolved
    }
    let created = try builder()
    resolved = created
    return created
  }
}
