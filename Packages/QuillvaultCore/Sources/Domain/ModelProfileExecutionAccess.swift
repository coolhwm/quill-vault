import Foundation

public struct ModelExecutionProfile: Equatable, Sendable {
  public let snapshot: ModelProfileSnapshot
  public let apiKey: String

  public init(snapshot: ModelProfileSnapshot, apiKey: String) {
    self.snapshot = snapshot
    self.apiKey = apiKey
  }
}

public protocol ModelProfileExecutionAccess: Sendable {
  func currentExecutionProfile() async throws -> ModelExecutionProfile
  func executionProfile(
    for snapshot: ModelProfileSnapshot
  ) async throws -> ModelExecutionProfile
  func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) async throws
  func finishTask(_ task: ModelProfileTaskReference) async throws
  func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) async throws
}
