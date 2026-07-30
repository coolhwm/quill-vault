import Domain

public struct MeetingLibraryWorkflow: MeetingLibraryUseCase {
  private let directoryAccess: any AuthoritativeDirectoryAccess
  private let catalog: any MeetingCatalog & MeetingSearchCatalog

  public init(
    directoryAccess: any AuthoritativeDirectoryAccess,
    catalog: any MeetingCatalog & MeetingSearchCatalog
  ) {
    self.directoryAccess = directoryAccess
    self.catalog = catalog
  }

  public func restore() async throws -> MeetingLibrarySnapshot {
    guard
      let directory = try await directoryAccess.restoreSelectedDirectory()
    else {
      throw DirectoryAccessError.bookmarkMissing
    }
    let indexedMeetings = try await catalog.meetings()
    guard indexedMeetings.isEmpty else {
      return MeetingLibrarySnapshot(
        directory: directory,
        meetings: indexedMeetings,
        diagnosticCount: 0
      )
    }
    return try await synchronize(directory)
  }

  public func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    let directory = try await directoryAccess.authorizeSelectedDirectory(selection)
    return try await load(directory)
  }

  public func rebuild() async throws -> MeetingLibrarySnapshot {
    guard
      let directory = try await directoryAccess.restoreSelectedDirectory()
    else {
      throw DirectoryAccessError.bookmarkMissing
    }
    let scan = try await directoryAccess.scan(directory)
    try await catalog.replaceAll(with: scan)
    return try await snapshot(directory: directory, scan: scan)
  }

  public func synchronize() async throws -> MeetingLibrarySnapshot {
    guard
      let directory = try await directoryAccess.restoreSelectedDirectory()
    else {
      throw DirectoryAccessError.bookmarkMissing
    }
    return try await synchronize(directory)
  }

  public func search(
    _ query: MeetingSearchQuery
  ) async throws -> [MeetingIndexEntry] {
    try await catalog.search(query)
  }

  private func load(
    _ directory: AuthoritativeDirectory
  ) async throws -> MeetingLibrarySnapshot {
    try await synchronize(directory)
  }

  private func synchronize(
    _ directory: AuthoritativeDirectory
  ) async throws -> MeetingLibrarySnapshot {
    let scan = try await directoryAccess.scan(directory)
    try await catalog.synchronize(with: scan)
    return try await snapshot(directory: directory, scan: scan)
  }

  private func snapshot(
    directory: AuthoritativeDirectory,
    scan: MeetingDirectoryScan
  ) async throws -> MeetingLibrarySnapshot {
    let meetings = try await catalog.meetings()
    return MeetingLibrarySnapshot(
      directory: directory,
      meetings: meetings,
      diagnosticCount: scan.diagnostics.count
    )
  }
}
