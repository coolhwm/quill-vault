public protocol MeetingCatalog: Sendable {
  func replaceAll(with scan: MeetingDirectoryScan) async throws
  func meetings() async throws -> [MeetingIndexEntry]
}
