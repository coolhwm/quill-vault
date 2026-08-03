public struct ModelCapability: Equatable, Sendable {
  public let providerDomain: String
  public let representativeContent: Bool

  public init(
    providerDomain: String,
    representativeContent: Bool
  ) {
    self.providerDomain = providerDomain
    self.representativeContent = representativeContent
  }
}

public struct AIRequest: Equatable, Sendable {
  public let systemPrompt: String
  public let userPrompt: String

  public init(systemPrompt: String, userPrompt: String) {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
  }
}

public enum AIEvent: Equatable, Sendable {
  case textDelta(String)
  case completed
}

public enum AIProviderError: Error, Equatable, Sendable {
  case insecureBaseURL
  case authentication
  case modelUnavailable
  case rateLimited
  case retryableRequest(statusCode: Int)
  case requestRejected(statusCode: Int)
  case serviceUnavailable(statusCode: Int)
  case incompatibleResponse
  case invalidResponse
  case networkUnavailable
}

public protocol AIProvider: Sendable {
  func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability

  func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error>
}
