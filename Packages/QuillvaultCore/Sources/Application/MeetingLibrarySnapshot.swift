import Domain

public struct MeetingLibrarySnapshot: Equatable, Sendable {
  public let directory: AuthoritativeDirectory
  public let meetings: [MeetingIndexEntry]
  public let diagnosticCount: Int

  public init(
    directory: AuthoritativeDirectory,
    meetings: [MeetingIndexEntry],
    diagnosticCount: Int
  ) {
    self.directory = directory
    self.meetings = meetings
    self.diagnosticCount = diagnosticCount
  }
}
