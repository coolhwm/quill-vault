import Domain
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OpenAICompatibleProvider: AIProvider {
  private let session: URLSession
  private static let maximumRetryAfterSeconds: TimeInterval = 300
  private let diagnostics: any DiagnosticRecorder

  public init(
    session: URLSession = .shared,
    diagnostics: any DiagnosticRecorder = NoopDiagnosticRecorder()
  ) {
    self.session = session
    self.diagnostics = diagnostics
  }

  public func test(
    profile: ModelProfileSnapshot,
    apiKey: String
  ) async throws -> ModelCapability {
    try await test(
      profile: profile,
      apiKey: apiKey,
      diagnosticContext: nil
    )
  }

  public func test(
    profile: ModelProfileSnapshot,
    apiKey: String,
    diagnosticContext: DiagnosticProviderContext?
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
    let startedAt = Date()
    let correlation = diagnosticContext?.correlation ?? DiagnosticCorrelation()
    await diagnostics.record(
      DiagnosticEvent(
        kind: .requestQueued,
        correlation: correlation,
        host: diagnosticContext?.host ?? profile.baseURL.host,
        model: diagnosticContext?.model ?? profile.model
      )
    )
    let metricsState = MetricsState()
    let delegate = URLSessionMetricsDelegate(
      context: diagnosticContext,
      fallbackHost: profile.baseURL.host,
      fallbackModel: profile.model,
      diagnostics: diagnostics,
      state: metricsState
    )
    do {
      let (data, response) = try await session.data(
        for: request,
        delegate: delegate
      )
      if metricsState.firstByteMilliseconds == nil {
        await diagnostics.record(
          DiagnosticEvent(
            kind: .providerFirstByte,
            correlation: correlation,
            durationMilliseconds: Self.milliseconds(since: startedAt),
            host: diagnosticContext?.host ?? profile.baseURL.host,
            model: diagnosticContext?.model ?? profile.model,
            firstByteMilliseconds: Self.milliseconds(since: startedAt)
          )
        )
      }
      try validate(response)
      let content = try Self.content(from: data)
      guard Self.isRepresentativeCapability(content) else {
        throw AIProviderError.incompatibleResponse
      }
      await diagnostics.record(
        DiagnosticEvent(
          kind: .responseCompleted,
          correlation: correlation,
          durationMilliseconds: Self.milliseconds(since: startedAt),
          byteCount: data.count,
          host: diagnosticContext?.host ?? profile.baseURL.host,
          model: diagnosticContext?.model ?? profile.model
        )
      )
      return ModelCapability(
        providerDomain: profile.baseURL.host ?? "",
        representativeContent: true
      )
    } catch is CancellationError {
      await diagnostics.record(
        Self.failureEvent(
          correlation: correlation,
          startedAt: startedAt,
          host: diagnosticContext?.host ?? profile.baseURL.host,
          model: diagnosticContext?.model ?? profile.model,
          errorCode: "cancelled"
        )
      )
      throw CancellationError()
    } catch let error as AIProviderError {
      await diagnostics.record(
        Self.failureEvent(
          correlation: correlation,
          startedAt: startedAt,
          host: diagnosticContext?.host ?? profile.baseURL.host,
          model: diagnosticContext?.model ?? profile.model,
          errorCode: Self.diagnosticErrorCode(error)
        )
      )
      throw error
    } catch let error as URLError where error.code == .cancelled {
      await diagnostics.record(
        Self.failureEvent(
          correlation: correlation,
          startedAt: startedAt,
          host: diagnosticContext?.host ?? profile.baseURL.host,
          model: diagnosticContext?.model ?? profile.model,
          errorCode: "cancelled"
        )
      )
      throw CancellationError()
    } catch {
      await diagnostics.record(
        Self.failureEvent(
          correlation: correlation,
          startedAt: startedAt,
          host: diagnosticContext?.host ?? profile.baseURL.host,
          model: diagnosticContext?.model ?? profile.model,
          errorCode: "network_unavailable"
        )
      )
      throw AIProviderError.networkUnavailable
    }
  }

  public func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String
  ) -> AsyncThrowingStream<AIEvent, Error> {
    generate(
      request,
      profile: profile,
      apiKey: apiKey,
      diagnosticContext: nil
    )
  }

  public func generate(
    _ request: AIRequest,
    profile: ModelProfileSnapshot,
    apiKey: String,
    diagnosticContext: DiagnosticProviderContext?
  ) -> AsyncThrowingStream<AIEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let startedAt = Date()
        let correlation = diagnosticContext?.correlation ?? DiagnosticCorrelation()
        let host = diagnosticContext?.host ?? profile.baseURL.host
        let model = diagnosticContext?.model ?? profile.model
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
          await diagnostics.record(
            DiagnosticEvent(
              kind: .requestQueued,
              correlation: correlation,
              host: host,
              model: model
            )
          )
          if profile.parameters.usesStreaming {
            try await stream(
              urlRequest,
              continuation: continuation,
              profile: profile,
              diagnosticContext: diagnosticContext
            )
          } else {
            let delegate = URLSessionMetricsDelegate(
              context: diagnosticContext,
              fallbackHost: profile.baseURL.host,
              fallbackModel: profile.model,
              diagnostics: diagnostics,
              state: MetricsState()
            )
            let metricsState = delegate.state
            let startedAt = Date()
            let (data, response) = try await session.data(
              for: urlRequest,
              delegate: delegate
            )
            if metricsState.firstByteMilliseconds == nil {
              await diagnostics.record(
                DiagnosticEvent(
                  kind: .providerFirstByte,
                  correlation: correlation,
                  durationMilliseconds: Self.milliseconds(since: startedAt),
                  host: host,
                  model: model,
                  firstByteMilliseconds: Self.milliseconds(since: startedAt)
                )
              )
            }
            try validate(response)
            continuation.yield(.textDelta(try Self.content(from: data)))
            continuation.yield(.completed)
            let usage = Self.usage(from: data)
            await diagnostics.record(
              DiagnosticEvent(
                kind: .providerStreamEnd,
                correlation: diagnosticContext?.correlation ?? DiagnosticCorrelation(),
                durationMilliseconds: Self.milliseconds(since: startedAt),
                byteCount: data.count,
                host: diagnosticContext?.host ?? profile.baseURL.host,
                model: diagnosticContext?.model ?? profile.model,
                providerPromptTokens: usage?.prompt,
                providerCompletionTokens: usage?.completion,
                providerTotalTokens: usage?.total
              )
            )
            continuation.finish()
          }
        } catch is CancellationError {
          await diagnostics.record(
            Self.failureEvent(
              correlation: correlation,
              startedAt: startedAt,
              host: host,
              model: model,
              errorCode: "cancelled"
            )
          )
          continuation.finish(throwing: CancellationError())
        } catch let error as AIProviderError {
          await diagnostics.record(
            Self.failureEvent(
              correlation: correlation,
              startedAt: startedAt,
              host: host,
              model: model,
              errorCode: Self.diagnosticErrorCode(error)
            )
          )
          continuation.finish(throwing: error)
        } catch let error as URLError where error.code == .cancelled {
          await diagnostics.record(
            Self.failureEvent(
              correlation: correlation,
              startedAt: startedAt,
              host: host,
              model: model,
              errorCode: "cancelled"
            )
          )
          continuation.finish(throwing: CancellationError())
        } catch {
          await diagnostics.record(
            Self.failureEvent(
              correlation: correlation,
              startedAt: startedAt,
              host: host,
              model: model,
              errorCode: "network_unavailable"
            )
          )
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
    continuation: AsyncThrowingStream<AIEvent, Error>.Continuation,
    profile: ModelProfileSnapshot,
    diagnosticContext: DiagnosticProviderContext?
  ) async throws {
    let delegate = URLSessionMetricsDelegate(
      context: diagnosticContext,
      fallbackHost: profile.baseURL.host,
      fallbackModel: profile.model,
      diagnostics: diagnostics,
      state: MetricsState()
    )
    let startedAt = Date()
    let (bytes, response) = try await session.bytes(
      for: request,
      delegate: delegate
    )
    try validate(response)
    var decoder = ServerSentEventDecoder()
    var sawFirstByte = false
    var usage: ResponseUsage?
    for try await byte in bytes {
      try Task.checkCancellation()
      if !sawFirstByte {
        sawFirstByte = true
        await diagnostics.record(
          DiagnosticEvent(
            kind: .providerFirstByte,
            correlation: diagnosticContext?.correlation ?? DiagnosticCorrelation(),
            durationMilliseconds: Self.milliseconds(since: startedAt),
            host: diagnosticContext?.host ?? profile.baseURL.host,
            model: diagnosticContext?.model ?? profile.model
          )
        )
      }
      for payload in try decoder.append(Data([byte])) {
        if payload == "[DONE]" {
          continuation.yield(.completed)
          await diagnostics.record(
            DiagnosticEvent(
              kind: .providerStreamEnd,
              correlation: diagnosticContext?.correlation ?? DiagnosticCorrelation(),
              durationMilliseconds: Self.milliseconds(since: startedAt),
              host: diagnosticContext?.host ?? profile.baseURL.host,
              model: diagnosticContext?.model ?? profile.model,
              providerPromptTokens: usage?.prompt,
              providerCompletionTokens: usage?.completion,
              providerTotalTokens: usage?.total
            )
          )
          continuation.finish()
          return
        }
        let data = Data(payload.utf8)
        usage = Self.usage(from: data) ?? usage
        if let content = try Self.optionalContent(from: data),
          !content.isEmpty
        {
          continuation.yield(.textDelta(content))
        }
      }
    }
    await diagnostics.record(
      DiagnosticEvent(
        kind: .providerStreamEnd,
        correlation: diagnosticContext?.correlation ?? DiagnosticCorrelation(),
        durationMilliseconds: Self.milliseconds(since: startedAt),
        host: diagnosticContext?.host ?? profile.baseURL.host,
        model: diagnosticContext?.model ?? profile.model,
        providerPromptTokens: usage?.prompt,
        providerCompletionTokens: usage?.completion,
        providerTotalTokens: usage?.total
      )
    )
    throw AIProviderError.invalidResponse
  }

  private static func milliseconds(since start: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(start) * 1_000))
  }

  private static func failureEvent(
    correlation: DiagnosticCorrelation,
    startedAt: Date,
    host: String?,
    model: String?,
    errorCode: String
  ) -> DiagnosticEvent {
    DiagnosticEvent(
      kind: .responseCompleted,
      correlation: correlation,
      durationMilliseconds: milliseconds(since: startedAt),
      host: host,
      model: model,
      errorCode: errorCode
    )
  }

  private static func diagnosticErrorCode(_ error: AIProviderError) -> String {
    switch error {
    case .insecureBaseURL: "insecure_base_url"
    case .authentication: "authentication"
    case .modelUnavailable: "model_unavailable"
    case .rateLimited, .rateLimitedWithRetryAfter: "rate_limited"
    case .retryableRequest: "retryable_request"
    case .requestRejected: "request_rejected"
    case .serviceUnavailable: "service_unavailable"
    case .requestTooLarge: "request_too_large"
    case .incompatibleResponse: "incompatible_response"
    case .invalidResponse: "invalid_response"
    case .networkUnavailable: "network_unavailable"
    }
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
    var request = URLRequest(url: profile.baseURL)
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
        stream: streaming,
        streamOptions: streaming ? StreamOptions(includeUsage: true) : nil
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

  private static func usage(from data: Data) -> ResponseUsage? {
    guard
      let response = try? JSONDecoder().decode(ResponseDTO.self, from: data),
      let usage = response.usage
    else {
      return nil
    }
    return ResponseUsage(
      prompt: usage.promptTokens,
      completion: usage.completionTokens,
      total: usage.totalTokens
    )
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

private final class URLSessionMetricsDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let context: DiagnosticProviderContext?
  private let fallbackHost: String?
  private let fallbackModel: String?
  private let diagnostics: any DiagnosticRecorder
  fileprivate let state: MetricsState

  init(
    context: DiagnosticProviderContext?,
    fallbackHost: String?,
    fallbackModel: String?,
    diagnostics: any DiagnosticRecorder,
    state: MetricsState
  ) {
    self.context = context
    self.fallbackHost = fallbackHost
    self.fallbackModel = fallbackModel
    self.diagnostics = diagnostics
    self.state = state
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    guard let transaction = metrics.transactionMetrics.last else { return }
    let start = transaction.fetchStartDate ?? metrics.taskInterval.start
    let event = DiagnosticEvent(
      kind: .networkMetrics,
      correlation: context?.correlation ?? DiagnosticCorrelation(),
      durationMilliseconds: Self.milliseconds(metrics.taskInterval.duration),
      statusCode: (task.response as? HTTPURLResponse)?.statusCode,
      host: context?.host ?? fallbackHost,
      model: context?.model ?? fallbackModel,
      queueWaitMilliseconds: Self.delta(
        metrics.taskInterval.start,
        transaction.fetchStartDate
      ),
      dnsMilliseconds: Self.delta(
        transaction.domainLookupStartDate,
        transaction.domainLookupEndDate
      ),
      tcpMilliseconds: Self.delta(
        transaction.connectStartDate,
        transaction.connectEndDate
      ),
      tlsMilliseconds: Self.delta(
        transaction.secureConnectionStartDate,
        transaction.secureConnectionEndDate
      ),
      requestSentMilliseconds: Self.delta(
        start,
        transaction.requestStartDate
      ),
      firstByteMilliseconds: Self.delta(
        start,
        transaction.responseStartDate
      ),
      responseCompleteMilliseconds: Self.delta(
        start,
        transaction.responseEndDate
      ),
      requestBytes: Int(transaction.countOfRequestBodyBytesSent),
      responseBytes: Int(transaction.countOfResponseBodyBytesReceived),
      networkProtocol: transaction.networkProtocolName,
      connectionReused: transaction.isReusedConnection,
      networkExpensive: transaction.isExpensive,
      networkConstrained: transaction.isConstrained
    )
    state.markFirstByte(event.firstByteMilliseconds)
    Task {
      await diagnostics.record(event)
      await recordStage(
        .dnsLookup,
        duration: event.dnsMilliseconds,
        correlation: event.correlation,
        host: event.host,
        model: event.model
      )
      await recordStage(
        .tcpConnection,
        duration: event.tcpMilliseconds,
        correlation: event.correlation,
        host: event.host,
        model: event.model
      )
      await recordStage(
        .tlsHandshake,
        duration: event.tlsMilliseconds,
        correlation: event.correlation,
        host: event.host,
        model: event.model
      )
      if let firstByte = event.firstByteMilliseconds {
        await diagnostics.record(
          DiagnosticEvent(
            kind: .providerFirstByte,
            correlation: event.correlation,
            durationMilliseconds: firstByte,
            host: event.host,
            model: event.model,
            firstByteMilliseconds: firstByte
          )
        )
      }
    }
  }

  private func recordStage(
    _ kind: DiagnosticEventKind,
    duration: Int?,
    correlation: DiagnosticCorrelation,
    host: String?,
    model: String?
  ) async {
    guard let duration else { return }
    await diagnostics.record(
      DiagnosticEvent(
        kind: kind,
        correlation: correlation,
        durationMilliseconds: duration,
        host: host,
        model: model
      )
    )
  }

  private static func milliseconds(_ interval: TimeInterval) -> Int {
    max(0, Int(interval * 1_000))
  }

  private static func delta(_ start: Date?, _ end: Date?) -> Int? {
    guard let start, let end else { return nil }
    return milliseconds(end.timeIntervalSince(start))
  }
}

private final class MetricsState: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int?

  var firstByteMilliseconds: Int? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func markFirstByte(_ milliseconds: Int?) {
    guard let milliseconds else { return }
    lock.lock()
    value = milliseconds
    lock.unlock()
  }
}

private struct RequestDTO: Encodable {
  let model: String
  let messages: [MessageDTO]
  let temperature: Double
  let maximumOutputTokens: Int
  let stream: Bool
  let streamOptions: StreamOptions?

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case maximumOutputTokens = "max_tokens"
    case stream
    case streamOptions = "stream_options"
  }
}

private struct StreamOptions: Encodable {
  let includeUsage: Bool

  enum CodingKeys: String, CodingKey {
    case includeUsage = "include_usage"
  }
}

private struct MessageDTO: Codable {
  let role: String
  let content: String
}

private struct ResponseDTO: Decodable {
  let choices: [ChoiceDTO]
  let usage: UsageDTO?
}

private struct UsageDTO: Decodable {
  let promptTokens: Int?
  let completionTokens: Int?
  let totalTokens: Int?

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
  }
}

private struct ResponseUsage {
  let prompt: Int?
  let completion: Int?
  let total: Int?
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
