import Application
import Domain
import Foundation
import Testing

@Suite("Model profile workflow")
struct ModelProfileWorkflowTests {
  @Test("Multiple named profiles can be saved and one selected without exposing keys")
  func savesAndSelectsProfiles() async throws {
    let profiles = ModelProfileStoreStub()
    let credentials = ModelCredentialStoreStub()
    let workflow = ModelProfileWorkflow(
      profiles: profiles,
      credentials: credentials,
      provider: AIProviderStub()
    )

    let first = try await workflow.save(
      ModelProfileDraft(
        name: "Fast",
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "fast-model",
        apiKey: "secret-one"
      )
    )
    let second = try await workflow.save(
      ModelProfileDraft(
        name: "Careful",
        baseURL: URL(string: "https://careful.example.com")!,
        model: "careful-model",
        apiKey: "secret-two"
      )
    )
    _ = try await workflow.test(second.id)
    try await workflow.select(second.id)

    let collection = try await workflow.load()
    #expect(collection.profiles.map(\.name) == ["Fast", "Careful"])
    #expect(collection.currentProfileID == second.id)
    #expect(await credentials.secret(for: first.credentialReference) == "secret-one")
    #expect(await credentials.secret(for: second.credentialReference) == "secret-two")
    #expect(!String(describing: collection).contains("secret-one"))
    #expect(!String(describing: collection).contains("secret-two"))
  }

  @Test("An existing task snapshot is unchanged when the current profile is edited")
  func snapshotIsolation() async throws {
    let workflow = ModelProfileWorkflow(
      profiles: ModelProfileStoreStub(),
      credentials: ModelCredentialStoreStub(),
      provider: AIProviderStub()
    )
    let profile = try await workflow.save(
      ModelProfileDraft(
        name: "Primary",
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "model-v1",
        apiKey: "secret"
      )
    )
    let taskSnapshot = profile.snapshot()

    _ = try await workflow.save(
      ModelProfileDraft(
        id: profile.id,
        name: "Primary",
        baseURL: profile.baseURL,
        model: "model-v2",
        credentialReference: profile.credentialReference,
        apiKey: nil
      )
    )

    #expect(taskSnapshot.model == "model-v1")
    #expect(taskSnapshot.credentialReference == profile.credentialReference)
  }

  @Test("Capability-affecting edits require verification again")
  func editInvalidatesCapability() async throws {
    let workflow = ModelProfileWorkflow(
      profiles: ModelProfileStoreStub(),
      credentials: ModelCredentialStoreStub(),
      provider: AIProviderStub()
    )
    let profile = try await workflow.save(
      ModelProfileDraft(
        name: "Primary",
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "model-v1",
        apiKey: "secret"
      )
    )
    _ = try await workflow.test(profile.id)
    try await workflow.setAutomaticGeneration(
      enabled: true,
      disclosureAcknowledged: true
    )

    _ = try await workflow.save(
      ModelProfileDraft(
        id: profile.id,
        name: profile.name,
        baseURL: profile.baseURL,
        model: "model-v2",
        credentialReference: profile.credentialReference,
        apiKey: nil
      )
    )

    let collection = try await workflow.load()
    #expect(collection.profiles.first?.isUsable == false)
    #expect(collection.currentProfileID == nil)
    #expect(collection.automaticGeneration.isEnabled == false)
  }

  @Test("Capability testing uses the saved credential and representative provider result")
  func testsRealCapability() async throws {
    let provider = AIProviderRecorder()
    let workflow = ModelProfileWorkflow(
      profiles: ModelProfileStoreStub(),
      credentials: ModelCredentialStoreStub(),
      provider: provider
    )
    let profile = try await workflow.save(
      ModelProfileDraft(
        name: "Primary",
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "minutes-model",
        apiKey: "saved-secret"
      )
    )

    let capability = try await workflow.test(profile.id)

    #expect(capability.representativeContent)
    #expect(await provider.lastAPIKey == "saved-secret")
    #expect(await provider.lastProfile?.model == "minutes-model")
    #expect(try await workflow.load().profiles.first?.isUsable == true)
  }

  @Test("Only verified profiles can become current or enable automatic generation")
  func usableSelectionAndDisclosure() async throws {
    let profiles = ModelProfileStoreStub()
    let workflow = ModelProfileWorkflow(
      profiles: profiles,
      credentials: ModelCredentialStoreStub(),
      provider: AIProviderStub()
    )
    let profile = try await workflow.save(
      ModelProfileDraft(
        name: "Primary",
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "minutes-model",
        apiKey: "secret"
      )
    )

    await #expect(throws: ModelProfileWorkflowError.profileNotUsable) {
      try await workflow.select(profile.id)
    }
    _ = try await workflow.test(profile.id)
    await #expect(
      throws:
        ModelProfileWorkflowError
        .automaticGenerationDisclosureRequired
    ) {
      try await workflow.setAutomaticGeneration(
        enabled: true,
        disclosureAcknowledged: false
      )
    }
    try await workflow.setAutomaticGeneration(
      enabled: true,
      disclosureAcknowledged: true
    )

    let collection = try await workflow.load()
    #expect(collection.currentProfileID == profile.id)
    #expect(collection.automaticGeneration.isEnabled)
    #expect(collection.automaticGeneration.disclosureAcknowledged)
  }

  @Test("Deleting a profile used by unfinished work requires explicit confirmation")
  func deletionProtection() async throws {
    let profiles = ModelProfileStoreStub()
    let credentials = ModelCredentialStoreStub()
    let workflow = ModelProfileWorkflow(
      profiles: profiles,
      credentials: credentials,
      provider: AIProviderStub(),
      usage: ModelProfileUsageStub(unfinishedCount: 2)
    )
    let profile = try await workflow.save(
      ModelProfileDraft(
        name: "In use",
        baseURL: URL(string: "https://api.example.com")!,
        model: "model",
        apiKey: "secret"
      )
    )

    #expect(
      try await workflow.deletionImpact(profile.id)
        == .unfinishedTasks(count: 2)
    )
    await #expect(throws: ModelProfileWorkflowError.deletionConfirmationRequired) {
      try await workflow.delete(profile.id, confirmed: false)
    }
    try await workflow.delete(profile.id, confirmed: true)

    #expect(try await workflow.load().profiles.isEmpty)
    #expect(await credentials.secret(for: profile.credentialReference) == nil)
  }
}

private actor ModelProfileStoreStub: ModelProfileStore {
  private var profiles: [ModelProfile] = []
  private var currentID: ModelProfileID?
  private var automaticGeneration = AutomaticGenerationPreferences()

  func loadAll() async throws -> [ModelProfile] {
    profiles
  }

  func save(_ profile: ModelProfile) async throws {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
  }

  func currentProfileID() async throws -> ModelProfileID? {
    currentID
  }

  func setCurrentProfileID(_ id: ModelProfileID?) async throws {
    currentID = id
  }

  func automaticGenerationPreferences() async throws
    -> AutomaticGenerationPreferences
  {
    automaticGeneration
  }

  func setAutomaticGenerationPreferences(
    _ preferences: AutomaticGenerationPreferences
  ) async throws {
    automaticGeneration = preferences
  }

  func delete(_ id: ModelProfileID) async throws {
    profiles.removeAll { $0.id == id }
  }
}

private actor ModelCredentialStoreStub: ModelCredentialStore {
  private var secrets: [ModelCredentialReference: String] = [:]

  func save(_ secret: String, for reference: ModelCredentialReference) async throws {
    secrets[reference] = secret
  }

  func read(_ reference: ModelCredentialReference) async throws -> String {
    guard let secret = secrets[reference] else {
      throw ModelCredentialError.notFound
    }
    return secret
  }

  func delete(_ reference: ModelCredentialReference) async throws {
    secrets[reference] = nil
  }

  func secret(for reference: ModelCredentialReference) -> String? {
    secrets[reference]
  }
}

private struct AIProviderStub: AIProvider {
  func test(profile: ModelProfileSnapshot, apiKey: String) async throws -> ModelCapability {
    ModelCapability(providerDomain: profile.baseURL.host ?? "", representativeContent: true)
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

private actor AIProviderRecorder: AIProvider {
  private(set) var lastProfile: ModelProfileSnapshot?
  private(set) var lastAPIKey: String?

  func test(profile: ModelProfileSnapshot, apiKey: String) async throws -> ModelCapability {
    lastProfile = profile
    lastAPIKey = apiKey
    return ModelCapability(
      providerDomain: profile.baseURL.host ?? "",
      representativeContent: true
    )
  }

  nonisolated func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

private struct ModelProfileUsageStub: ModelProfileUsageChecking {
  let unfinishedCount: Int

  func unfinishedTaskCount(for profileID: ModelProfileID) async throws -> Int {
    unfinishedCount
  }
}
