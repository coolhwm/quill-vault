import Domain
import Foundation
import Testing

@testable import ModelServices

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("OpenAI-compatible provider", .serialized)
struct OpenAICompatibleProviderTests {
  @Test("A real minimal request validates representative minutes content")
  func capabilityProbe() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer top-secret")
      let body = try requestBody(request)
      let text = String(decoding: body, as: UTF8.self)
      #expect(text.contains("quillvault_capability"))
      #expect(!text.contains("recording.m4a"))
      #expect(!text.contains("file://"))
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )!,
        Data(
          """
          {"choices":[{"message":{"content":"```json\\n{\\"quillvault_capability\\":\\"ready\\",\\"summary\\":\\"可用纪要\\"}\\n```"}}]}
          """.utf8
        )
      )
    }
    let provider = OpenAICompatibleProvider(session: transport.session)

    let result = try await provider.test(
      profile: profile(streaming: false),
      apiKey: "top-secret"
    )

    #expect(result.representativeContent)
    #expect(result.providerDomain == "api.example.com")
  }

  @Test("HTTP success without representative content remains incompatible")
  func incompatibleSuccess() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
      )
    }
    let provider = OpenAICompatibleProvider(session: transport.session)

    await #expect(throws: AIProviderError.incompatibleResponse) {
      _ = try await provider.test(
        profile: profile(streaming: false),
        apiKey: "secret"
      )
    }
  }

  @Test("Compatible content arrays are decoded tolerantly")
  func tolerantContentArray() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(
          """
          {"choices":[{"message":{"content":[{"type":"text","text":"{\\"quillvault_capability\\":\\"ready\\",\\"summary\\":\\"usable\\"}"}]}}]}
          """.utf8
        )
      )
    }

    let result = try await OpenAICompatibleProvider(
      session: transport.session
    ).test(profile: profile(streaming: false), apiKey: "secret")

    #expect(result.representativeContent)
  }

  @Test("Non-streaming generation emits content and completion")
  func nonStreamingGeneration() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      let body = try requestBody(request)
      #expect(String(decoding: body, as: UTF8.self).contains(#""stream":false"#))
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )!,
        Data(
          #"{"choices":[{"message":{"content":"usable minutes"}}]}"#.utf8
        )
      )
    }
    let stream = OpenAICompatibleProvider(
      session: transport.session
    ).generate(
      AIRequest(systemPrompt: "system", userPrompt: "meeting text"),
      profile: profile(streaming: false),
      apiKey: "secret"
    )

    var events: [AIEvent] = []
    for try await event in stream {
      events.append(event)
    }

    #expect(events == [.textDelta("usable minutes"), .completed])
  }

  @Test("Generation forwards the stable step idempotency key")
  func generationForwardsIdempotencyKey() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "stable-step-key")
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data(#"{"choices":[{"message":{"content":"usable minutes"}}]}"#.utf8)
      )
    }
    let stream = OpenAICompatibleProvider(
      session: transport.session
    ).generate(
      AIRequest(
        systemPrompt: "system",
        userPrompt: "meeting text",
        idempotencyKey: "stable-step-key"
      ),
      profile: profile(streaming: false),
      apiKey: "secret"
    )

    var events: [AIEvent] = []
    for try await event in stream {
      events.append(event)
    }

    #expect(events == [.textDelta("usable minutes"), .completed])
  }

  @Test("Insecure provider URLs are rejected before transport")
  func insecureURL() async {
    let provider = OpenAICompatibleProvider()
    let insecureProfile = ModelProfileSnapshot(
      profileID: ModelProfileID(rawValue: UUID()),
      baseURL: URL(string: "http://api.example.com/v1")!,
      model: "minutes-model",
      parameters: ModelGenerationParameters(usesStreaming: false),
      credentialReference: ModelCredentialReference(rawValue: UUID())
    )

    await #expect(throws: AIProviderError.insecureBaseURL) {
      _ = try await provider.test(
        profile: insecureProfile,
        apiKey: "secret"
      )
    }
  }

  @Test(
    "HTTP failures map to stable provider errors",
    arguments: [
      (401, AIProviderError.authentication),
      (403, AIProviderError.authentication),
      (404, AIProviderError.modelUnavailable),
      (408, AIProviderError.retryableRequest(statusCode: 408)),
      (429, AIProviderError.rateLimited),
      (500, AIProviderError.serviceUnavailable(statusCode: 500)),
    ]
  )
  func statusMapping(status: Int, expected: AIProviderError) async {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: status,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data()
      )
    }
    let provider = OpenAICompatibleProvider(session: transport.session)

    do {
      _ = try await provider.test(
        profile: profile(streaming: false),
        apiKey: "secret"
      )
      Issue.record("Expected provider error")
    } catch let error as AIProviderError {
      #expect(error == expected)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("429 Retry-After is preserved for bounded backoff")
  func rateLimitRetryAfter() async {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 429,
          httpVersion: nil,
          headerFields: ["Retry-After": "3"]
        )!,
        Data()
      )
    }
    let provider = OpenAICompatibleProvider(session: transport.session)

    await #expect(
      throws: AIProviderError.rateLimitedWithRetryAfter(seconds: 3)
    ) {
      _ = try await provider.test(
        profile: profile(streaming: false),
        apiKey: "secret"
      )
    }
  }

  @Test("An excessive Retry-After is bounded instead of overflowing the scheduler")
  func excessiveRetryAfterIsBounded() async {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 429,
          httpVersion: nil,
          headerFields: ["Retry-After": "100000000000000000000"]
        )!,
        Data()
      )
    }
    let provider = OpenAICompatibleProvider(session: transport.session)

    await #expect(
      throws: AIProviderError.rateLimitedWithRetryAfter(seconds: 300)
    ) {
      _ = try await provider.test(
        profile: profile(streaming: false),
        apiKey: "secret"
      )
    }
  }

  @Test("Streaming generation emits deltas and a single completion")
  func streamingGeneration() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/event-stream"]
        )!,
        Data(
          "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\ndata: [DONE]\n\n"
            .utf8
        )
      )
    }
    let stream = OpenAICompatibleProvider(
      session: transport.session
    ).generate(
      AIRequest(systemPrompt: "system", userPrompt: "user"),
      profile: profile(streaming: true),
      apiKey: "secret"
    )

    var events: [AIEvent] = []
    for try await event in stream {
      events.append(event)
    }

    #expect(events == [.textDelta("你"), .textDelta("好"), .completed])
  }

  @Test("Streaming ignores legal role and finish chunks")
  func streamingControlChunks() async throws {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/event-stream"]
        )!,
        Data(
          ("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"ready\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: [DONE]\n\n").utf8
        )
      )
    }

    var events: [AIEvent] = []
    for try await event in OpenAICompatibleProvider(
      session: transport.session
    ).generate(
      AIRequest(systemPrompt: "system", userPrompt: "user"),
      profile: profile(streaming: true),
      apiKey: "secret"
    ) {
      events.append(event)
    }

    #expect(events == [.textDelta("ready"), .completed])
  }

  @Test("Streaming EOF without DONE is rejected as incomplete")
  func truncatedStreamingResponse() async {
    let transport = URLProtocolTransport()
    transport.respond { request in
      (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/event-stream"]
        )!,
        Data(
          "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
            .utf8
        )
      )
    }

    do {
      for try await _ in OpenAICompatibleProvider(
        session: transport.session
      ).generate(
        AIRequest(systemPrompt: "system", userPrompt: "user"),
        profile: profile(streaming: true),
        apiKey: "secret"
      ) {}
      Issue.record("Expected incomplete stream failure")
    } catch let error as AIProviderError {
      #expect(error == .invalidResponse)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("Cancelling a streaming consumer cancels the URLSession task")
  func cancellation() async throws {
    HoldingURLProtocol.state.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HoldingURLProtocol.self]
    let provider = OpenAICompatibleProvider(
      session: URLSession(configuration: configuration)
    )
    let stream = provider.generate(
      AIRequest(systemPrompt: "system", userPrompt: "user"),
      profile: profile(streaming: true),
      apiKey: "secret"
    )
    let consumer = Task {
      for try await _ in stream {}
    }

    try await Task.sleep(for: .milliseconds(20))
    consumer.cancel()
    _ = try? await consumer.value
    for _ in 0..<20 where !HoldingURLProtocol.state.wasStopped {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(HoldingURLProtocol.state.wasStopped)
  }

  @Test("SSE decoding survives arbitrary UTF-8 byte boundaries")
  func splitUTF8SSE() throws {
    var decoder = ServerSentEventDecoder()
    let source = Data(
      "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n"
        .utf8
    )
    var events: [String] = []
    for byte in source {
      events += try decoder.append(Data([byte]))
    }

    #expect(events.count == 2)
    #expect(try #require(events.first).contains("你好"))
    #expect(try #require(events.last) == "[DONE]")
  }

  private func profile(streaming: Bool) -> ModelProfileSnapshot {
    ModelProfileSnapshot(
      profileID: ModelProfileID(rawValue: UUID()),
      baseURL: URL(string: "https://api.example.com/v1")!,
      model: "minutes-model",
      parameters: ModelGenerationParameters(usesStreaming: streaming),
      credentialReference: ModelCredentialReference(rawValue: UUID())
    )
  }
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody {
    return body
  }
  let stream = try #require(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 1_024)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count >= 0 else {
      throw AIProviderError.invalidResponse
    }
    if count == 0 {
      break
    }
    data.append(buffer, count: count)
  }
  return data
}

private final class URLProtocolTransport: @unchecked Sendable {
  typealias Handler =
    @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledURLProtocol.self]
    session = URLSession(configuration: configuration)
  }

  func respond(_ handler: @escaping Handler) {
    ControlledURLProtocol.setHandler(handler)
  }
}

private final class ControlledURLProtocol: URLProtocol, @unchecked Sendable {
  private static let state = URLProtocolHandlerState()

  static func setHandler(
    _ handler: @escaping URLProtocolTransport.Handler
  ) {
    state.set(handler)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(
    for request: URLRequest
  ) -> URLRequest {
    request
  }

  override func startLoading() {
    do {
      let handler = try #require(Self.state.get())
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private final class URLProtocolHandlerState: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: URLProtocolTransport.Handler?

  func set(_ handler: @escaping URLProtocolTransport.Handler) {
    lock.withLock {
      self.handler = handler
    }
  }

  func get() -> URLProtocolTransport.Handler? {
    lock.withLock {
      handler
    }
  }
}

private final class HoldingURLProtocol: URLProtocol, @unchecked Sendable {
  static let state = URLProtocolCancellationState()

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(
    for request: URLRequest
  ) -> URLRequest {
    request
  }

  override func startLoading() {}

  override func stopLoading() {
    Self.state.recordStop()
  }
}

private final class URLProtocolCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  var wasStopped: Bool {
    lock.withLock { stopped }
  }

  func reset() {
    lock.withLock {
      stopped = false
    }
  }

  func recordStop() {
    lock.withLock {
      stopped = true
    }
  }
}
