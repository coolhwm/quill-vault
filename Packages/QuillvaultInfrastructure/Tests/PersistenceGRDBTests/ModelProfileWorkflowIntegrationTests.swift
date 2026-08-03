import Application
import Domain
import Foundation
import ModelServices
import Testing

@testable import PersistenceGRDB

@Suite("Model profile persistence integration")
struct ModelProfileWorkflowIntegrationTests {
  @Test("The real workflow persists a new profile and its Keychain credential")
  func persistsProfileAndCredential() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appending(path: "model-profile-integration-\(UUID().uuidString)")
      .appending(path: "profiles.sqlite")
    let service = "com.coolhwm.Quillvault.tests.\(UUID().uuidString)"
    let reference = ModelCredentialReference(rawValue: UUID())
    let store = try GRDBModelProfileStore.open(at: databaseURL)
    let credentials = KeychainModelCredentialStore(service: service)
    defer {
      try? FileManager.default.removeItem(
        at: databaseURL.deletingLastPathComponent()
      )
    }
    let workflow = ModelProfileWorkflow(
      profiles: store,
      credentials: credentials,
      provider: IntegrationAIProviderStub()
    )

    let profile = try await workflow.save(
      ModelProfileDraft(
        name: "Primary",
        baseURL: URL(string: "https://api.example.com/v1/chat/completions")!,
        model: "minutes-model",
        credentialReference: reference,
        apiKey: "integration-secret"
      )
    )

    #expect(try await store.loadAll() == [profile])
    #expect(try await credentials.read(reference) == "integration-secret")
    try await credentials.delete(reference)
  }
}

private struct IntegrationAIProviderStub: AIProvider {
  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    ModelCapability(
      providerDomain: profile.baseURL.host ?? "",
      representativeContent: true
    )
  }

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}
