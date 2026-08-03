import Foundation

public protocol ModelProfileStore: Sendable {
  func loadAll() async throws -> [ModelProfile]
  func save(_ profile: ModelProfile) async throws
  func currentProfileID() async throws -> ModelProfileID?
  func setCurrentProfileID(_ id: ModelProfileID?) async throws
  func automaticGenerationPreferences() async throws
    -> AutomaticGenerationPreferences
  func setAutomaticGenerationPreferences(
    _ preferences: AutomaticGenerationPreferences
  ) async throws
  func delete(_ id: ModelProfileID) async throws
}

public struct AutomaticGenerationPreferences: Equatable, Sendable {
  public var isEnabled: Bool
  public var disclosureAcknowledged: Bool

  public init(
    isEnabled: Bool = false,
    disclosureAcknowledged: Bool = false
  ) {
    self.isEnabled = isEnabled
    self.disclosureAcknowledged = disclosureAcknowledged
  }
}

public protocol ModelCredentialStore: Sendable {
  func save(
    _ secret: String,
    for reference: ModelCredentialReference
  ) async throws
  func read(_ reference: ModelCredentialReference) async throws -> String
  func delete(_ reference: ModelCredentialReference) async throws
}

public protocol ModelProfileUsageChecking: Sendable {
  func unfinishedTaskCount(
    for profileID: ModelProfileID
  ) async throws -> Int
}

public struct ModelProfileTaskReference: Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

public protocol ModelProfileUsageTracking:
  ModelProfileUsageChecking
{
  func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) async throws
  func finishTask(_ task: ModelProfileTaskReference) async throws
}

public enum ModelProfileDeletionImpact: Equatable, Sendable {
  case safe
  case unfinishedTasks(count: Int)
}

public enum ModelCredentialError: Error, Equatable, Sendable {
  case notFound
  case unavailableUntilFirstUnlock
  case unavailable
}

public enum ModelProfileStoreError: Error, Equatable, Sendable {
  case unavailable
  case invalidData
}
