import Domain

public protocol MeetingLibraryUseCase: Sendable {
  func restore() async throws -> MeetingLibrarySnapshot
  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot
  func rebuild() async throws -> MeetingLibrarySnapshot
  func synchronize() async throws -> MeetingLibrarySnapshot
  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry]
}

extension MeetingLibraryUseCase {
  public func synchronize() async throws -> MeetingLibrarySnapshot {
    try await restore()
  }
}
