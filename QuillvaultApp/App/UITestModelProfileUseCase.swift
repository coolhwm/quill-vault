import Application
import Domain
import Foundation

actor UITestModelProfileUseCase: ModelProfileUseCase {
  private static let seededID = ModelProfileID(
    rawValue: UUID(
      uuidString: "19A00000-0000-0000-0000-000000000001"
    )!
  )
  private var profiles: [ModelProfile]
  private var currentID: ModelProfileID?
  private var automaticGeneration = AutomaticGenerationPreferences()
  private var transcriptQuality = TranscriptQualityPreferences()

  init() {
    let id = Self.seededID
    profiles = [
      ModelProfile(
        id: id,
        name: "Fast",
        baseURL: URL(string: "https://api.example.com/v1/chat/completions")!,
        model: "minutes-model",
        parameters: ModelGenerationParameters(usesStreaming: true),
        credentialReference: ModelCredentialReference(
          rawValue: UUID(
            uuidString: "19A00000-0000-0000-0000-000000000002"
          )!
        ),
        isUsable: true
      )
    ]
    currentID = id
  }

  func load() async throws -> ModelProfileCollection {
    ModelProfileCollection(
      profiles: profiles,
      currentProfileID: currentID,
      automaticGeneration: automaticGeneration,
      transcriptQuality: transcriptQuality
    )
  }

  func save(_ draft: ModelProfileDraft) async throws -> ModelProfile {
    let profile = ModelProfile(
      id: draft.id ?? Self.seededID,
      name: draft.name,
      baseURL: draft.baseURL,
      model: draft.model,
      parameters: draft.parameters,
      credentialReference: draft.credentialReference
        ?? ModelCredentialReference(
          rawValue: UUID(
            uuidString: "19A00000-0000-0000-0000-000000000002"
          )!
        ),
      isUsable: false
    )
    profiles.removeAll { $0.id == profile.id }
    profiles.append(profile)
    currentID = currentID ?? profile.id
    return profile
  }

  func select(_ id: ModelProfileID) async throws {
    currentID = id
  }

  func test(_ id: ModelProfileID) async throws -> ModelCapability {
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      profiles[index].isUsable = true
    }
    return ModelCapability(
      providerDomain: "api.example.com",
      representativeContent: true
    )
  }

  func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async throws {
    automaticGeneration = AutomaticGenerationPreferences(
      isEnabled: enabled,
      disclosureAcknowledged:
        disclosureAcknowledged
        || automaticGeneration.disclosureAcknowledged
    )
  }

  func setTranscriptQuality(enabled: Bool) async throws {
    transcriptQuality = TranscriptQualityPreferences(isEnabled: enabled)
  }

  func deletionImpact(
    _ id: ModelProfileID
  ) async throws -> ModelProfileDeletionImpact {
    .safe
  }

  func delete(
    _ id: ModelProfileID,
    confirmed: Bool
  ) async throws {
    profiles.removeAll { $0.id == id }
    if currentID == id {
      currentID = nil
    }
  }
}
