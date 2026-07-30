public protocol MeetingCatalog: Sendable {
  func replaceAll(with scan: MeetingDirectoryScan) async throws
  func synchronize(with scan: MeetingDirectoryScan) async throws
  func meetings() async throws -> [MeetingIndexEntry]
}

extension MeetingCatalog {
  public func synchronize(with scan: MeetingDirectoryScan) async throws {
    try await replaceAll(with: scan)
  }
}
