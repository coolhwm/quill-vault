import Domain

public protocol MeetingLibraryUseCase: Sendable {
  func restore() async throws -> MeetingLibrarySnapshot
  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot
  func rebuild() async throws -> MeetingLibrarySnapshot
}
