import Domain
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OpenAICompatibleProvider: AIProvider {
  private let session: URLSession
  private static let maximumRetryAfterSeconds: TimeInterval = 300

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    let request = try makeURLRequest(
      profile: profile,
      apiKey: apiKey,
      messages: [
        MessageDTO(
          role: "system",
          content: """
            Return only a compact JSON object. Do not use Markdown.
            """
        ),
        MessageDTO(
          role: "user",
          content: """
            Capability probe: summarize "A team approved the launch."
            Return {"quillvault_capability":"ready","summary":"..."}.
            """
        ),
      ],
      streaming: false
    )
    do {
      let (data, response) = try await session.data(for: request)
      try validate(response)
      let content = try Self.content(from: data)
      guard Self.isRepresentativeCapability(content) else {
        throw AIProviderError.incompatibleResponse
      }
      return ModelCapability(
        providerDomain: profile.baseURL.host ?? "",
        representativeContent: true
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AIProviderError {
      throw error
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw AIProviderError.networkUnavailable
    }
  }

  public func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeURLRequest(
            profile: profile,
            apiKey: apiKey,
            messages: [
              MessageDTO(role: "system", content: request.systemPrompt),
              MessageDTO(role: "user", content: request.userPrompt),
            ],
            streaming: profile.parameters.usesStreaming,
            idempotencyKey: request.idempotencyKey
          )
          if profile.parameters.usesStreaming {
            try await stream(
              urlRequest,
              continuation: continuation
            )
          } else {
            let (data, response) = try await session.data(for: urlRequest)
            try validate(response)
            continuation.yield(.textDelta(try Self.content(from: data)))
            continuation.yield(.completed)
            continuation.finish()
          }
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as AIProviderError {
          continuation.finish(throwing: error)
        } catch let error as URLError where error.code == .cancelled {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: AIProviderError.networkUnavailable)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func stream(
    _ request: URLRequest,
    continuation: AsyncThrowingStream<AIEvent, Error>.Continuation
  ) async throws {
    let (bytes, response) = try await session.bytes(for: request)
    try validate(response)
    var decoder = ServerSentEventDecoder()
    for try await byte in bytes {
      try Task.checkCancellation()
      for payload in try decoder.append(Data([byte])) {
        if payload == "[DONE]" {
          continuation.yield(.completed)
          continuation.finish()
          return
        }
        let data = Data(payload.utf8)
        if let content = try Self.optionalContent(from: data),
          !content.isEmpty
        {
          continuation.yield(.textDelta(content))
        }
      }
    }
    throw AIProviderError.invalidResponse
  }

  private func makeURLRequest(
    profile: ModelProfileSnapshot,
    apiKey: String,
    messages: [MessageDTO],
    streaming: Bool,
    idempotencyKey: String? = nil
  ) throws -> URLRequest {
    guard profile.baseURL.scheme?.lowercased() == "https" else {
      throw AIProviderError.insecureBaseURL
    }
    let endpoint = profile.baseURL
      .appending(path: "chat")
      .appending(path: "completions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    if let idempotencyKey {
      request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    }
    request.httpBody = try JSONEncoder().encode(
      RequestDTO(
        model: profile.model,
        messages: messages,
        temperature: profile.parameters.temperature,
        maximumOutputTokens: profile.parameters.maximumOutputTokens,
        stream: streaming
      )
    )
    return request
  }

  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse else {
      throw AIProviderError.invalidResponse
    }
    switch response.statusCode {
    case 200..<300:
      return
    case 401, 403:
      throw AIProviderError.authentication
    case 404:
      throw AIProviderError.modelUnavailable
    case 429:
      if let retryAfter = retryAfterSeconds(from: response) {
        throw AIProviderError.rateLimitedWithRetryAfter(seconds: retryAfter)
      }
      throw AIProviderError.rateLimited
    case 408:
      throw AIProviderError.retryableRequest(
        statusCode: response.statusCode
      )
    case 413:
      throw AIProviderError.requestTooLarge
    case 500..<600:
      throw AIProviderError.serviceUnavailable(
        statusCode: response.statusCode
      )
    default:
      throw AIProviderError.requestRejected(
        statusCode: response.statusCode
      )
    }
  }

  private func retryAfterSeconds(
    from response: HTTPURLResponse
  ) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
      return nil
    }
    if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
      return min(Self.maximumRetryAfterSeconds, seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else {
      return nil
    }
    return min(
      Self.maximumRetryAfterSeconds,
      max(0, date.timeIntervalSinceNow)
    )
  }

  private static func content(from data: Data) throws -> String {
    guard let content = try optionalContent(from: data) else {
      throw AIProviderError.invalidResponse
    }
    return content
  }

  private static func optionalContent(from data: Data) throws -> String? {
    let response: ResponseDTO
    do {
      response = try JSONDecoder().decode(ResponseDTO.self, from: data)
    } catch {
      throw AIProviderError.invalidResponse
    }
    return response.choices.compactMap(\.content).first
  }

  private static func isRepresentativeCapability(
    _ content: String
  ) -> Bool {
    guard let start = content.firstIndex(of: "{"),
      let end = content.lastIndex(of: "}"),
      start <= end,
      let data = String(content[start...end]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
      object["quillvault_capability"] as? String == "ready",
      let summary = object["summary"] as? String,
      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }
    return true
  }
}

private struct RequestDTO: Encodable {
  let model: String
  let messages: [MessageDTO]
  let temperature: Double
  let maximumOutputTokens: Int
  let stream: Bool

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case maximumOutputTokens = "max_tokens"
    case stream
  }
}

private struct MessageDTO: Codable {
  let role: String
  let content: String
}

private struct ResponseDTO: Decodable {
  let choices: [ChoiceDTO]
}

private struct ChoiceDTO: Decodable {
  let message: ResponseMessageDTO?
  let delta: ResponseMessageDTO?

  var content: String? {
    message?.content?.text ?? delta?.content?.text
  }
}

private struct ResponseMessageDTO: Decodable {
  let content: ResponseContentDTO?
}

private struct ResponseContentDTO: Decodable {
  let text: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self.text = text
      return
    }
    let parts = try container.decode([TextPartDTO].self)
    text = parts.compactMap(\.text).joined()
  }
}

private struct TextPartDTO: Decodable {
  let text: String?
}
