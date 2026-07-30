public enum MeetingScanDiagnosticCode: String, Codable, Sendable {
  case candidateIgnored
  case invalidManifest
  case invalidMarkdown
  case itemNotDownloaded
  case noRecognizedAssets
  case unreadableEntry
}

public struct MeetingScanDiagnostic: Equatable, Sendable {
  public let code: MeetingScanDiagnosticCode
  public let relativePathDigest: String

  public init(
    code: MeetingScanDiagnosticCode,
    relativePathDigest: String
  ) {
    self.code = code
    self.relativePathDigest = relativePathDigest
  }
}
