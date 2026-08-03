import Foundation

/// Stable, non-content identifiers used to correlate a diagnostic event.
///
/// The values in this type are deliberately limited to identifiers generated
/// by the application. Titles, file names, directory references and model
/// payloads must never be put here.
public struct DiagnosticCorrelation: Codable, Equatable, Hashable, Sendable {
  public let meetingID: UUID?
  public let jobID: UUID?
  public let stepID: String?
  public let attemptID: UUID?

  private enum CodingKeys: String, CodingKey {
    case meetingID = "meeting_id"
    case jobID = "job_id"
    case stepID = "step_id"
    case attemptID = "attempt_id"
  }

  public init(
    meetingID: UUID? = nil,
    jobID: UUID? = nil,
    stepID: String? = nil,
    attemptID: UUID? = nil
  ) {
    self.meetingID = meetingID
    self.jobID = jobID
    self.stepID = Self.sanitizeIdentifier(stepID)
    self.attemptID = attemptID
  }

  private static func sanitizeIdentifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let sanitized = value.filter { character in
      character.isASCII
        && (character.isLetter || character.isNumber || "._-".contains(character))
    }
    guard !sanitized.isEmpty else { return nil }
    return String(sanitized.prefix(128))
  }
}

public struct DiagnosticProviderContext: Equatable, Sendable {
  public let correlation: DiagnosticCorrelation
  public let host: String?
  public let model: String?

  public init(
    correlation: DiagnosticCorrelation,
    host: String? = nil,
    model: String? = nil
  ) {
    self.correlation = correlation
    self.host = host
    self.model = model
  }
}

public enum DiagnosticEventKind: String, Codable, CaseIterable, Sendable {
  case requestQueued
  case dnsLookup
  case tcpConnection
  case tlsHandshake
  case requestSent
  case providerFirstByte
  case providerStreamEnd
  case responseCompleted
  case parseCompleted
  case checkpointSaved
  case publishCompleted
  case retryScheduled
  case backgroundScheduled
  case backgroundStarted
  case backgroundCompleted
  case recordingStarted
  case recordingFinished
  case transcriptionStarted
  case transcriptionFinished
  case networkMetrics
}

/// A redacted diagnostic event. Every field is a bounded scalar; there is no
/// field for request headers, API credentials, payloads, transcript text or
/// file paths.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let kind: DiagnosticEventKind
  public let correlation: DiagnosticCorrelation
  public let durationMilliseconds: Int?
  public let statusCode: Int?
  public let byteCount: Int?
  public let host: String?
  public let model: String?
  public let attempt: Int?
  public let retryAfterMilliseconds: Int?
  public let queueWaitMilliseconds: Int?
  public let dnsMilliseconds: Int?
  public let tcpMilliseconds: Int?
  public let tlsMilliseconds: Int?
  public let requestSentMilliseconds: Int?
  public let firstByteMilliseconds: Int?
  public let responseCompleteMilliseconds: Int?
  public let requestBytes: Int?
  public let responseBytes: Int?
  public let providerPromptTokens: Int?
  public let providerCompletionTokens: Int?
  public let providerTotalTokens: Int?
  public let networkProtocol: String?
  public let connectionReused: Bool?
  public let networkExpensive: Bool?
  public let networkConstrained: Bool?
  public let errorCode: String?

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    kind: DiagnosticEventKind,
    correlation: DiagnosticCorrelation = DiagnosticCorrelation(),
    durationMilliseconds: Int? = nil,
    statusCode: Int? = nil,
    byteCount: Int? = nil,
    host: String? = nil,
    model: String? = nil,
    attempt: Int? = nil,
    retryAfterMilliseconds: Int? = nil,
    queueWaitMilliseconds: Int? = nil,
    dnsMilliseconds: Int? = nil,
    tcpMilliseconds: Int? = nil,
    tlsMilliseconds: Int? = nil,
    requestSentMilliseconds: Int? = nil,
    firstByteMilliseconds: Int? = nil,
    responseCompleteMilliseconds: Int? = nil,
    requestBytes: Int? = nil,
    responseBytes: Int? = nil,
    providerPromptTokens: Int? = nil,
    providerCompletionTokens: Int? = nil,
    providerTotalTokens: Int? = nil,
    networkProtocol: String? = nil,
    connectionReused: Bool? = nil,
    networkExpensive: Bool? = nil,
    networkConstrained: Bool? = nil,
    errorCode: String? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.correlation = correlation
    self.durationMilliseconds = Self.nonNegative(durationMilliseconds)
    self.statusCode = statusCode.map { min(max($0, 100), 599) }
    self.byteCount = Self.nonNegative(byteCount)
    self.host = Self.sanitizeHost(host)
    self.model = Self.sanitizeIdentifier(model, maximumLength: 128)
    self.attempt = Self.nonNegative(attempt)
    self.retryAfterMilliseconds = Self.nonNegative(retryAfterMilliseconds)
    self.queueWaitMilliseconds = Self.nonNegative(queueWaitMilliseconds)
    self.dnsMilliseconds = Self.nonNegative(dnsMilliseconds)
    self.tcpMilliseconds = Self.nonNegative(tcpMilliseconds)
    self.tlsMilliseconds = Self.nonNegative(tlsMilliseconds)
    self.requestSentMilliseconds = Self.nonNegative(requestSentMilliseconds)
    self.firstByteMilliseconds = Self.nonNegative(firstByteMilliseconds)
    self.responseCompleteMilliseconds = Self.nonNegative(responseCompleteMilliseconds)
    self.requestBytes = Self.nonNegative(requestBytes)
    self.responseBytes = Self.nonNegative(responseBytes)
    self.providerPromptTokens = Self.nonNegative(providerPromptTokens)
    self.providerCompletionTokens = Self.nonNegative(providerCompletionTokens)
    self.providerTotalTokens = Self.nonNegative(providerTotalTokens)
    self.networkProtocol = Self.sanitizeIdentifier(networkProtocol, maximumLength: 32)
    self.connectionReused = connectionReused
    self.networkExpensive = networkExpensive
    self.networkConstrained = networkConstrained
    self.errorCode = Self.sanitizeIdentifier(errorCode, maximumLength: 64)
  }

  private static func nonNegative(_ value: Int?) -> Int? {
    value.map { max(0, $0) }
  }

  private static func sanitizeScalar(
    _ value: String?,
    maximumLength: Int
  ) -> String? {
    guard let value else { return nil }
    let sanitized = value.filter { character in
      !character.isNewline
        && character.unicodeScalars.allSatisfy { scalar in
          scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
    guard !sanitized.isEmpty else { return nil }
    return String(sanitized.prefix(maximumLength))
  }

  /// Model names, protocol names and error codes are identifiers, not free
  /// text. Keeping them to a small ASCII alphabet prevents accidental export
  /// of a prompt, response fragment or local path through a diagnostic field.
  private static func sanitizeIdentifier(
    _ value: String?,
    maximumLength: Int
  ) -> String? {
    guard let value else { return nil }
    let sanitized = value.filter { character in
      character.isASCII
        && (character.isLetter || character.isNumber || "._:-".contains(character))
    }
    guard !sanitized.isEmpty else { return nil }
    return String(sanitized.prefix(maximumLength))
  }

  private static func sanitizeHost(_ value: String?) -> String? {
    guard let value, !value.contains("/"), !value.contains("\\") else {
      return nil
    }
    return sanitizeScalar(value, maximumLength: 253)
  }
}

public struct DiagnosticPreview: Equatable, Sendable {
  public let eventCount: Int
  public let oldestEventAt: Date?
  public let newestEventAt: Date?
  public let retentionDays: Int

  public init(
    eventCount: Int,
    oldestEventAt: Date?,
    newestEventAt: Date?,
    retentionDays: Int = 14
  ) {
    self.eventCount = max(0, eventCount)
    self.oldestEventAt = oldestEventAt
    self.newestEventAt = newestEventAt
    self.retentionDays = max(1, retentionDays)
  }
}

public struct DiagnosticExport: Equatable, Sendable {
  public let filename: String
  public let data: Data

  public init(filename: String = "quillvault-diagnostics.json", data: Data) {
    self.filename = filename
    self.data = data
  }
}

public struct DiagnosticExportPackage: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let generatedAt: Date
  public let retentionDays: Int
  public let privacy: String
  public let events: [DiagnosticEvent]
  public let performance: [DiagnosticPerformanceAttribution.Summary]

  public init(
    schemaVersion: String = "v1",
    generatedAt: Date = Date(),
    retentionDays: Int = 14,
    privacy: String =
      "On-device diagnostics only. No credentials, request headers, payloads, user content or private locations are included.",
    events: [DiagnosticEvent],
    performance: [DiagnosticPerformanceAttribution.Summary]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.retentionDays = max(1, retentionDays)
    self.privacy = privacy
    self.events = events
    self.performance =
      performance
      ?? DiagnosticPerformanceAttribution.summaries(
        for: events
      )
  }
}

public protocol DiagnosticRecorder: Sendable {
  func record(_ event: DiagnosticEvent) async
}

public protocol DiagnosticStore: DiagnosticRecorder, Sendable {
  func recentEvents(limit: Int) async throws -> [DiagnosticEvent]
  func diagnosticPreview() async throws -> DiagnosticPreview
  func exportPackage() async throws -> DiagnosticExportPackage
}

public enum DiagnosticStoreError: Error, Equatable, Sendable {
  case unavailable
  case invalidData
}

public struct NoopDiagnosticRecorder: DiagnosticRecorder, Sendable {
  public init() {}

  public func record(_ event: DiagnosticEvent) async {}
}

public actor NoopDiagnosticStore: DiagnosticStore {
  public init() {}

  public func record(_ event: DiagnosticEvent) async {}

  public func recentEvents(limit: Int) async throws -> [DiagnosticEvent] {
    throw DiagnosticStoreError.unavailable
  }

  public func diagnosticPreview() async throws -> DiagnosticPreview {
    throw DiagnosticStoreError.unavailable
  }

  public func exportPackage() async throws -> DiagnosticExportPackage {
    throw DiagnosticStoreError.unavailable
  }
}

/// Small, deterministic privacy guard used by automated export tests and by
/// the settings export path before data leaves the app through a user action.
public enum DiagnosticPrivacyAudit {
  public static func forbiddenMarkers(in data: Data) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      return ["non-utf8-export"]
    }

    var findings = Set<String>()
    inspect(object, keyPath: nil, findings: &findings)
    return findings.sorted()
  }

  private static let forbiddenKeyFragments = [
    "authorization",
    "api_key",
    "apikey",
    "secret",
    "password",
    "header",
    "body",
    "payload",
    "transcript",
    "minutes",
    "audio",
    "path",
    "url",
  ]

  private static let forbiddenExactKeys = [
    "token",
    "access_token",
    "refresh_token",
    "id_token",
  ]

  private static func inspect(
    _ value: Any,
    keyPath: String?,
    findings: inout Set<String>
  ) {
    switch value {
    case let dictionary as [String: Any]:
      for (key, nested) in dictionary {
        let normalizedKey = key.lowercased()
        if forbiddenExactKeys.contains(normalizedKey)
          || forbiddenKeyFragments.contains(where: { normalizedKey.contains($0) })
        {
          findings.insert(normalizedKey)
        }
        inspect(nested, keyPath: normalizedKey, findings: &findings)
      }
    case let array as [Any]:
      for nested in array {
        inspect(nested, keyPath: keyPath, findings: &findings)
      }
    case let string as String:
      let normalized = string.lowercased()
      if normalized.contains("bearer ") {
        findings.insert("bearer ")
      }
      if normalized.contains("sk-") || normalized.contains("api_key")
        || normalized.contains("authorization:")
      {
        findings.insert("credential-marker")
      }
      if normalized.contains("/private/") || normalized.contains("\\private\\")
        || normalized.contains("/users/") || normalized.contains("\\users\\")
        || normalized.contains("/var/mobile/")
      {
        findings.insert("private-location")
      }
      if normalized.contains("httpbody") || normalized.contains(".m4a")
        || normalized.contains(".md")
        || normalized.contains("transcript:")
      {
        findings.insert("httpbody")
      }
    default:
      break
    }
  }
}
