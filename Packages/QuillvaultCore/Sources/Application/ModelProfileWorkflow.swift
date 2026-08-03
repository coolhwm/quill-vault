import Domain
import Foundation

public actor ModelProfileWorkflow: ModelProfileUseCase {
  private let profiles: any ModelProfileStore
  private let credentials: any ModelCredentialStore
  private let provider: any AIProvider
  private let usage: any ModelProfileUsageChecking
  private let makeProfileID: @Sendable () -> ModelProfileID
  private let makeCredentialReference: @Sendable () -> ModelCredentialReference

  public init(
    profiles: any ModelProfileStore,
    credentials: any ModelCredentialStore,
    provider: any AIProvider,
    usage: (any ModelProfileUsageChecking)? = nil,
    makeProfileID: @escaping @Sendable () -> ModelProfileID = {
      ModelProfileID(rawValue: UUID())
    },
    makeCredentialReference:
      @escaping @Sendable () -> ModelCredentialReference = {
        ModelCredentialReference(rawValue: UUID())
      }
  ) {
    self.profiles = profiles
    self.credentials = credentials
    self.provider = provider
    self.usage = usage ?? EmptyModelProfileUsage()
    self.makeProfileID = makeProfileID
    self.makeCredentialReference = makeCredentialReference
  }

  public func load() async throws -> ModelProfileCollection {
    ModelProfileCollection(
      profiles: try await profiles.loadAll(),
      currentProfileID: try await profiles.currentProfileID(),
      automaticGeneration:
        try await profiles.automaticGenerationPreferences()
    )
  }

  public func save(_ draft: ModelProfileDraft) async throws -> ModelProfile {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw ModelProfileWorkflowError.invalidName
    }
    guard draft.baseURL.scheme?.lowercased() == "https",
      draft.baseURL.host != nil
    else {
      throw ModelProfileWorkflowError.invalidBaseURL
    }
    let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else {
      throw ModelProfileWorkflowError.invalidModel
    }

    let existing =
      try await profiles.loadAll().first { $0.id == draft.id }
    let id = existing?.id ?? draft.id ?? makeProfileID()
    let reference =
      existing?.credentialReference
      ?? draft.credentialReference
      ?? makeCredentialReference()
    var previousSecret: String?
    if let apiKey = draft.apiKey, !apiKey.isEmpty {
      if existing != nil {
        previousSecret = try await credentials.read(reference)
      }
      try await credentials.save(apiKey, for: reference)
    } else if draft.id == nil {
      throw ModelProfileWorkflowError.missingCredential
    }

    let profile = ModelProfile(
      id: id,
      name: name,
      baseURL: draft.baseURL,
      model: model,
      parameters: draft.parameters,
      credentialReference: reference,
      isUsable:
        existing?.isUsable == true
        && existing?.baseURL == draft.baseURL
        && existing?.model == model
        && existing?.parameters == draft.parameters
        && draft.apiKey == nil
    )
    do {
      try await profiles.save(profile)
    } catch {
      if let previousSecret {
        try? await credentials.save(previousSecret, for: reference)
      } else if draft.id == nil {
        try? await credentials.delete(reference)
      }
      throw error
    }
    if try await profiles.currentProfileID() == profile.id,
      !profile.isUsable
    {
      try await profiles.setCurrentProfileID(nil)
      var preferences =
        try await profiles.automaticGenerationPreferences()
      preferences.isEnabled = false
      try await profiles.setAutomaticGenerationPreferences(preferences)
    }
    return profile
  }

  public func select(_ id: ModelProfileID) async throws {
    guard
      let profile = try await profiles.loadAll().first(where: { $0.id == id })
    else {
      throw ModelProfileWorkflowError.profileNotFound
    }
    guard profile.isUsable else {
      throw ModelProfileWorkflowError.profileNotUsable
    }
    try await profiles.setCurrentProfileID(id)
  }

  public func test(_ id: ModelProfileID) async throws -> ModelCapability {
    guard let profile = try await profiles.loadAll().first(where: { $0.id == id }) else {
      throw ModelProfileWorkflowError.profileNotFound
    }
    do {
      let apiKey = try await credentials.read(profile.credentialReference)
      let capability = try await provider.test(
        profile: profile.snapshot(),
        apiKey: apiKey
      )
      var verifiedProfile = profile
      verifiedProfile.isUsable = true
      try await profiles.save(verifiedProfile)
      if try await profiles.currentProfileID() == nil {
        try await profiles.setCurrentProfileID(id)
      }
      return capability
    } catch {
      var unavailableProfile = profile
      unavailableProfile.isUsable = false
      try? await profiles.save(unavailableProfile)
      let currentID = try? await profiles.currentProfileID()
      if currentID == id {
        try? await profiles.setCurrentProfileID(nil)
        if var preferences =
          try? await profiles.automaticGenerationPreferences()
        {
          preferences.isEnabled = false
          try? await profiles.setAutomaticGenerationPreferences(preferences)
        }
      }
      throw error
    }
  }

  public func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async throws {
    var preferences = try await profiles.automaticGenerationPreferences()
    if enabled {
      guard disclosureAcknowledged || preferences.disclosureAcknowledged else {
        throw ModelProfileWorkflowError
          .automaticGenerationDisclosureRequired
      }
      guard
        let currentID = try await profiles.currentProfileID(),
        try await profiles.loadAll().contains(where: {
          $0.id == currentID && $0.isUsable
        })
      else {
        throw ModelProfileWorkflowError.profileNotUsable
      }
      preferences.disclosureAcknowledged = true
    }
    preferences.isEnabled = enabled
    try await profiles.setAutomaticGenerationPreferences(preferences)
  }

  public func deletionImpact(
    _ id: ModelProfileID
  ) async throws -> ModelProfileDeletionImpact {
    let count = try await usage.unfinishedTaskCount(for: id)
    return count == 0 ? .safe : .unfinishedTasks(count: count)
  }

  public func delete(
    _ id: ModelProfileID,
    confirmed: Bool
  ) async throws {
    guard let profile = try await profiles.loadAll().first(where: { $0.id == id }) else {
      throw ModelProfileWorkflowError.profileNotFound
    }
    if try await usage.unfinishedTaskCount(for: id) > 0, !confirmed {
      throw ModelProfileWorkflowError.deletionConfirmationRequired
    }
    try await profiles.delete(id)
    try await credentials.delete(profile.credentialReference)
    if try await profiles.currentProfileID() == id {
      try await profiles.setCurrentProfileID(nil)
      try await profiles.setAutomaticGenerationPreferences(
        AutomaticGenerationPreferences(
          isEnabled: false,
          disclosureAcknowledged:
            try await profiles.automaticGenerationPreferences()
            .disclosureAcknowledged
        )
      )
    }
  }
}

private struct EmptyModelProfileUsage: ModelProfileUsageChecking {
  func unfinishedTaskCount(
    for profileID: ModelProfileID
  ) async throws -> Int {
    0
  }
}
