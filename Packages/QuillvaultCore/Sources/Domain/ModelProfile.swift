import Foundation

public struct ModelProfileID: Hashable, Codable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

public struct ModelCredentialReference: Hashable, Codable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

public struct ModelGenerationParameters: Hashable, Codable, Sendable {
  public var temperature: Double
  public var maximumOutputTokens: Int
  public var usesStreaming: Bool

  public init(
    temperature: Double = 0.2,
    maximumOutputTokens: Int = 4_096,
    usesStreaming: Bool = true
  ) {
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.usesStreaming = usesStreaming
  }
}

public struct ModelProfile: Hashable, Codable, Sendable {
  public let id: ModelProfileID
  public var name: String
  public var baseURL: URL
  public var model: String
  public var parameters: ModelGenerationParameters
  public let credentialReference: ModelCredentialReference
  public var isUsable: Bool

  public init(
    id: ModelProfileID,
    name: String,
    baseURL: URL,
    model: String,
    parameters: ModelGenerationParameters = ModelGenerationParameters(),
    credentialReference: ModelCredentialReference,
    isUsable: Bool = false
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.model = model
    self.parameters = parameters
    self.credentialReference = credentialReference
    self.isUsable = isUsable
  }

  public func snapshot() -> ModelProfileSnapshot {
    ModelProfileSnapshot(
      profileID: id,
      baseURL: baseURL,
      model: model,
      parameters: parameters,
      credentialReference: credentialReference
    )
  }
}

public struct ModelProfileSnapshot: Hashable, Codable, Sendable {
  public let profileID: ModelProfileID
  public let baseURL: URL
  public let model: String
  public let parameters: ModelGenerationParameters
  public let credentialReference: ModelCredentialReference

  public init(
    profileID: ModelProfileID,
    baseURL: URL,
    model: String,
    parameters: ModelGenerationParameters,
    credentialReference: ModelCredentialReference
  ) {
    self.profileID = profileID
    self.baseURL = baseURL
    self.model = model
    self.parameters = parameters
    self.credentialReference = credentialReference
  }
}
