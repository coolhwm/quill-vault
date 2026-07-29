public struct MeetingDirectoryScan: Equatable, Sendable {
  public let meetings: [MeetingIndexEntry]
  public let fingerprints: [MeetingFileFingerprint]
  public let diagnostics: [MeetingScanDiagnostic]

  public init(
    meetings: [MeetingIndexEntry],
    fingerprints: [MeetingFileFingerprint],
    diagnostics: [MeetingScanDiagnostic]
  ) {
    self.meetings = meetings
    self.fingerprints = fingerprints
    self.diagnostics = diagnostics
  }

  public static let empty = Self(meetings: [], fingerprints: [], diagnostics: [])
}
