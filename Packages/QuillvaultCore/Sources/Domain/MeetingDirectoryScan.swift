public struct MeetingDirectoryScan: Equatable, Sendable {
  public let meetings: [MeetingIndexEntry]
  public let fingerprints: [MeetingFileFingerprint]
  public let diagnostics: [MeetingScanDiagnostic]
  public let searchDocuments: [MeetingSearchDocument]

  public init(
    meetings: [MeetingIndexEntry],
    fingerprints: [MeetingFileFingerprint],
    diagnostics: [MeetingScanDiagnostic],
    searchDocuments: [MeetingSearchDocument] = []
  ) {
    self.meetings = meetings
    self.fingerprints = fingerprints
    self.diagnostics = diagnostics
    self.searchDocuments = searchDocuments
  }

  public static let empty = Self(
    meetings: [],
    fingerprints: [],
    diagnostics: [],
    searchDocuments: []
  )
}
