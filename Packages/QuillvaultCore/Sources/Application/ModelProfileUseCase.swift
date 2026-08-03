import Domain
import Foundation

public struct ModelProfileDraft: Sendable {
  public var id: ModelProfileID?
  public var name: String
  public var baseURL: URL
  public var model: String
  public var parameters: ModelGenerationParameters
  public var credentialReference: ModelCredentialReference?
  public var apiKey: String?

  public init(
    id: ModelProfileID? = nil,
    name: String,
    baseURL: URL,
    model: String,
    parameters: ModelGenerationParameters = ModelGenerationParameters(),
    credentialReference: ModelCredentialReference? = nil,
    apiKey: String?
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.model = model
    self.parameters = parameters
    self.credentialReference = credentialReference
    self.apiKey = apiKey
  }
}

public struct ModelProfileCollection: Equatable, Sendable {
  public let profiles: [ModelProfile]
  public let currentProfileID: ModelProfileID?
  public let automaticGeneration: AutomaticGenerationPreferences
  public let transcriptQuality: TranscriptQualityPreferences

  public init(
    profiles: [ModelProfile],
    currentProfileID: ModelProfileID?,
    automaticGeneration: AutomaticGenerationPreferences =
      AutomaticGenerationPreferences(),
    transcriptQuality: TranscriptQualityPreferences =
      TranscriptQualityPreferences()
  ) {
    self.profiles = profiles
    self.currentProfileID = currentProfileID
    self.automaticGeneration = automaticGeneration
    self.transcriptQuality = transcriptQuality
  }
}

public protocol ModelProfileUseCase: Sendable {
  func load() async throws -> ModelProfileCollection
  func save(_ draft: ModelProfileDraft) async throws -> ModelProfile
  func select(_ id: ModelProfileID) async throws
  func test(_ id: ModelProfileID) async throws -> ModelCapability
  func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async throws
  func setTranscriptQuality(enabled: Bool) async throws
  func deletionImpact(
    _ id: ModelProfileID
  ) async throws -> ModelProfileDeletionImpact
  func delete(_ id: ModelProfileID, confirmed: Bool) async throws
}

extension ModelProfileUseCase {
  public func setTranscriptQuality(enabled: Bool) async throws {}
}

public enum ModelProfileWorkflowError: Error, Equatable, Sendable {
  case invalidName
  case invalidBaseURL
  case invalidModel
  case missingCredential
  case profileNotFound
  case profileNotUsable
  case automaticGenerationDisclosureRequired
  case deletionConfirmationRequired
}

public enum ModelProfileValidation {
  public static func baseURLError(
    for baseURL: URL
  ) -> ModelProfileWorkflowError? {
    guard baseURL.scheme?.lowercased() == "https",
      baseURL.host != nil
    else {
      return .invalidBaseURL
    }
    return nil
  }
}
