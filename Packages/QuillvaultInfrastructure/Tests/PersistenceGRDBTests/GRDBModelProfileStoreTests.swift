import Application
import Domain
import Foundation
import PersistenceGRDB
import Testing

@Suite("GRDB model profile store")
struct GRDBModelProfileStoreTests {
  @Test("Profiles and current selection survive reopening without credentials")
  func persistence() async throws {
    let databaseURL = temporaryModelProfileDatabaseURL()
    let first = modelProfile(
      id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      credential: "11111111-1111-1111-1111-111111111111",
      name: "Fast"
    )
    let second = modelProfile(
      id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
      credential: "22222222-2222-2222-2222-222222222222",
      name: "Careful"
    )
    do {
      let store = try GRDBModelProfileStore.open(at: databaseURL)
      try await store.save(first)
      try await store.save(second)
      try await store.setCurrentProfileID(second.id)
      try await store.setAutomaticGenerationPreferences(
        AutomaticGenerationPreferences(
          isEnabled: true,
          disclosureAcknowledged: true
        )
      )
      try await store.close()
    }

    let reopened = try GRDBModelProfileStore.open(at: databaseURL)
    #expect(try await reopened.loadAll() == [first, second])
    #expect(try await reopened.currentProfileID() == second.id)
    #expect(
      try await reopened.automaticGenerationPreferences()
        == AutomaticGenerationPreferences(
          isEnabled: true,
          disclosureAcknowledged: true
        )
    )
    #expect(!String(describing: try await reopened.loadAll()).contains("api-key"))

    try await reopened.delete(second.id)
    #expect(try await reopened.loadAll() == [first])
  }

  @Test("Unfinished task associations drive deletion protection")
  func unfinishedUsage() async throws {
    let store = try GRDBModelProfileStore.open(
      at: temporaryModelProfileDatabaseURL()
    )
    let profile = modelProfile(
      id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      credential: "11111111-1111-1111-1111-111111111111",
      name: "In use"
    )
    let first = ModelProfileTaskReference(rawValue: UUID())
    let second = ModelProfileTaskReference(rawValue: UUID())
    try await store.save(profile)
    try await store.registerUnfinishedTask(first, profileID: profile.id)
    try await store.registerUnfinishedTask(second, profileID: profile.id)
    let orphan = ModelProfileTaskReference(rawValue: UUID())
    try await store.registerUnfinishedTask(orphan, profileID: profile.id)

    #expect(try await store.unfinishedTaskCount(for: profile.id) == 3)
    try await store.reconcileUnfinishedTasks(keeping: [first, second])
    #expect(try await store.unfinishedTaskCount(for: profile.id) == 2)
    let workflow = ModelProfileWorkflow(
      profiles: store,
      credentials: UnusedCredentialStore(),
      provider: UnusedAIProvider(),
      usage: store
    )
    #expect(
      try await workflow.deletionImpact(profile.id)
        == .unfinishedTasks(count: 2)
    )

    try await store.finishTask(first)
    #expect(try await store.unfinishedTaskCount(for: profile.id) == 1)

    try await store.delete(profile.id)
    #expect(try await store.unfinishedTaskCount(for: profile.id) == 0)
  }
}

private struct UnusedCredentialStore: ModelCredentialStore {
  func save(
    _ secret: String,
    for reference: ModelCredentialReference
  ) async throws {}

  func read(_ reference: ModelCredentialReference) async throws -> String {
    throw ModelCredentialError.notFound
  }

  func delete(_ reference: ModelCredentialReference) async throws {}
}

private struct UnusedAIProvider: AIProvider {
  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    throw AIProviderError.invalidResponse
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

private func modelProfile(
  id: String,
  credential: String,
  name: String
) -> ModelProfile {
  ModelProfile(
    id: ModelProfileID(rawValue: UUID(uuidString: id)!),
    name: name,
    baseURL: URL(string: "https://api.example.com/v1")!,
    model: "\(name.lowercased())-model",
    credentialReference: ModelCredentialReference(
      rawValue: UUID(uuidString: credential)!
    ),
    isUsable: true
  )
}

private func temporaryModelProfileDatabaseURL() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "model-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
  try! FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return directory.appending(path: "profiles.sqlite")
}
