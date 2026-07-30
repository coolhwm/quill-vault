import Domain

public enum AuthoritativeDirectoryRecovery: Equatable, Sendable {
  case chooseDirectory
  case renewAccess
  case downloadRequired
  case tryAgain
}

extension DirectoryAccessError {
  public var recovery: AuthoritativeDirectoryRecovery {
    switch self {
    case .bookmarkMissing:
      .chooseDirectory
    case .bookmarkStale, .permissionDenied, .directoryMoved:
      .renewAccess
    case .itemNotDownloaded:
      .downloadRequired
    case .unreadableDirectory, .invalidSelection, .coordinationFailed:
      .tryAgain
    }
  }
}

public protocol AuthoritativeDirectoryUseCase: Sendable {
  func restore() async throws -> AuthoritativeDirectory?
  func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory
}

public struct AuthoritativeDirectoryWorkflow: AuthoritativeDirectoryUseCase {
  private let access: any AuthoritativeDirectoryAccess

  public init(access: any AuthoritativeDirectoryAccess) {
    self.access = access
  }

  public func restore() async throws -> AuthoritativeDirectory? {
    try await access.restoreSelectedDirectory()
  }

  public func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    try await access.authorizeSelectedDirectory(selection)
  }
}
