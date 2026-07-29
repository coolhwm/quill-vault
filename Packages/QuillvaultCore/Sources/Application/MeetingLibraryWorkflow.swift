import Domain

public struct MeetingLibraryWorkflow: MeetingLibraryUseCase {
  private let directoryAccess: any AuthoritativeDirectoryAccess
  private let catalog: any MeetingCatalog

  public init(
    directoryAccess: any AuthoritativeDirectoryAccess,
    catalog: any MeetingCatalog
  ) {
    self.directoryAccess = directoryAccess
    self.catalog = catalog
  }

  public func restore() async throws -> MeetingLibrarySnapshot {
    let directory =
      if let selectedDirectory = try await directoryAccess.restoreSelectedDirectory() {
        selectedDirectory
      } else {
        try await directoryAccess.resolveDefaultDirectory()
      }
    return try await load(directory)
  }

  public func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    let directory = try await directoryAccess.authorizeSelectedDirectory(selection)
    return try await load(directory)
  }

  public func rebuild() async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  private func load(
    _ directory: AuthoritativeDirectory
  ) async throws -> MeetingLibrarySnapshot {
    let scan = try await directoryAccess.scan(directory)
    try await catalog.replaceAll(with: scan)
    let meetings = try await catalog.meetings()
    return MeetingLibrarySnapshot(
      directory: directory,
      meetings: meetings,
      diagnosticCount: scan.diagnostics.count
    )
  }
}
