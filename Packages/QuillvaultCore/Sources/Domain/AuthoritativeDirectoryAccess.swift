public struct AuthoritativeDirectorySelection: Sendable {
  public let opaqueReference: String

  public init(opaqueReference: String) {
    self.opaqueReference = opaqueReference
  }
}

public protocol AuthoritativeDirectoryAccess: Sendable {
  func restoreSelectedDirectory() async throws -> AuthoritativeDirectory?
  func authorizeSelectedDirectory(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory
  func scan(_ directory: AuthoritativeDirectory) async throws -> MeetingDirectoryScan
}
