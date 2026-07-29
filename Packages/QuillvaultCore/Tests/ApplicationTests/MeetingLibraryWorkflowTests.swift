import Application
import Domain
import Foundation
import Testing

@Suite("Meeting library workflow")
struct MeetingLibraryWorkflowTests {
  @Test("Restores a selected directory, scans it, and atomically replaces the index")
  func restoresSelectedDirectory() async throws {
    let meeting = MeetingIndexEntry.fixture()
    let directory = AuthoritativeDirectory.fixture(kind: .userSelected)
    let directoryAccess = DirectoryAccessStub(
      restoredDirectory: directory,
      scanResult: MeetingDirectoryScan(meetings: [meeting], fingerprints: [], diagnostics: [])
    )
    let index = MeetingCatalogStub()
    let workflow = MeetingLibraryWorkflow(
      directoryAccess: directoryAccess,
      catalog: index
    )

    let snapshot = try await workflow.restore()

    #expect(snapshot.directory == directory)
    #expect(snapshot.meetings == [meeting])
    #expect(await directoryAccess.defaultResolutionCount == 0)
    #expect(await index.replacements == [[meeting]])
  }

  @Test("Does not silently fall back when the selected directory can no longer be restored")
  func selectedDirectoryFailureDoesNotFallBack() async {
    let directoryAccess = DirectoryAccessStub(
      restoreError: .bookmarkStale,
      scanResult: .empty
    )
    let workflow = MeetingLibraryWorkflow(
      directoryAccess: directoryAccess,
      catalog: MeetingCatalogStub()
    )

    await #expect(throws: DirectoryAccessError.bookmarkStale) {
      _ = try await workflow.restore()
    }
    #expect(await directoryAccess.defaultResolutionCount == 0)
  }

  @Test("Uses the default iCloud directory only when no user selection exists")
  func usesDefaultOnlyWithoutSelection() async throws {
    let defaultDirectory = AuthoritativeDirectory.fixture(kind: .iCloudDefault)
    let directoryAccess = DirectoryAccessStub(
      restoredDirectory: nil,
      defaultDirectory: defaultDirectory,
      scanResult: .empty
    )
    let workflow = MeetingLibraryWorkflow(
      directoryAccess: directoryAccess,
      catalog: MeetingCatalogStub()
    )

    let snapshot = try await workflow.restore()

    #expect(snapshot.directory == defaultDirectory)
    #expect(await directoryAccess.defaultResolutionCount == 1)
  }

  @Test("Cancellation never replaces the existing meeting index")
  func cancellationDoesNotReplaceIndex() async {
    let directoryAccess = DirectoryAccessStub(
      restoredDirectory: .fixture(kind: .userSelected),
      scanError: CancellationError(),
      scanResult: .empty
    )
    let index = MeetingCatalogStub()
    let workflow = MeetingLibraryWorkflow(
      directoryAccess: directoryAccess,
      catalog: index
    )

    await #expect(throws: CancellationError.self) {
      _ = try await workflow.restore()
    }
    #expect(await index.replacements.isEmpty)
  }

  @Test("A failed catalog initialization is attempted again on retry")
  func retriesInitialization() async throws {
    let attempts = LibraryFactoryAttempts()
    let snapshot = MeetingLibrarySnapshot(
      directory: .fixture(kind: .iCloudDefault),
      meetings: [],
      diagnosticCount: 0
    )
    let retrying = RetryingMeetingLibraryUseCase {
      guard await attempts.beginAttempt() > 1 else {
        throw DirectoryAccessError.unreadableDirectory
      }
      return MeetingLibraryUseCaseStub(snapshot: snapshot)
    }

    await #expect(throws: DirectoryAccessError.unreadableDirectory) {
      _ = try await retrying.restore()
    }
    #expect(try await retrying.restore() == snapshot)
    #expect(await attempts.count == 2)
  }

  @Test("Concurrent cold-start calls share one library initialization")
  func coalescesConcurrentInitialization() async throws {
    let attempts = LibraryFactoryAttempts()
    let snapshot = MeetingLibrarySnapshot(
      directory: .fixture(kind: .iCloudDefault),
      meetings: [],
      diagnosticCount: 0
    )
    let retrying = RetryingMeetingLibraryUseCase {
      _ = await attempts.beginAttempt()
      try await Task.sleep(for: .milliseconds(50))
      return MeetingLibraryUseCaseStub(snapshot: snapshot)
    }

    let snapshots = try await withThrowingTaskGroup(
      of: MeetingLibrarySnapshot.self,
      returning: [MeetingLibrarySnapshot].self
    ) { group in
      for _ in 0..<20 {
        group.addTask {
          try await retrying.restore()
        }
      }

      var results: [MeetingLibrarySnapshot] = []
      for try await result in group {
        results.append(result)
      }
      return results
    }

    #expect(snapshots.count == 20)
    #expect(snapshots.allSatisfy { $0 == snapshot })
    #expect(await attempts.count == 1)
  }
}

private actor DirectoryAccessStub: AuthoritativeDirectoryAccess {
  private let restoredDirectory: AuthoritativeDirectory?
  private let defaultDirectory: AuthoritativeDirectory
  private let restoreError: DirectoryAccessError?
  private let scanError: (any Error & Sendable)?
  private let scanResult: MeetingDirectoryScan

  private(set) var defaultResolutionCount = 0

  init(
    restoredDirectory: AuthoritativeDirectory? = nil,
    defaultDirectory: AuthoritativeDirectory = .fixture(kind: .iCloudDefault),
    restoreError: DirectoryAccessError? = nil,
    scanError: (any Error & Sendable)? = nil,
    scanResult: MeetingDirectoryScan
  ) {
    self.restoredDirectory = restoredDirectory
    self.defaultDirectory = defaultDirectory
    self.restoreError = restoreError
    self.scanError = scanError
    self.scanResult = scanResult
  }

  func restoreSelectedDirectory() async throws -> AuthoritativeDirectory? {
    if let restoreError {
      throw restoreError
    }
    return restoredDirectory
  }

  func resolveDefaultDirectory() async throws -> AuthoritativeDirectory {
    defaultResolutionCount += 1
    return defaultDirectory
  }

  func authorizeSelectedDirectory(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    AuthoritativeDirectory.fixture(kind: .userSelected)
  }

  func scan(_ directory: AuthoritativeDirectory) async throws -> MeetingDirectoryScan {
    if let scanError {
      throw scanError
    }
    return scanResult
  }
}

private actor MeetingCatalogStub: MeetingCatalog {
  private(set) var replacements: [[MeetingIndexEntry]] = []

  func replaceAll(with scan: MeetingDirectoryScan) async throws {
    replacements.append(scan.meetings)
  }

  func meetings() async throws -> [MeetingIndexEntry] {
    replacements.last ?? []
  }
}

private actor LibraryFactoryAttempts {
  private(set) var count = 0

  func beginAttempt() -> Int {
    count += 1
    return count
  }
}

private struct MeetingLibraryUseCaseStub: MeetingLibraryUseCase {
  let snapshot: MeetingLibrarySnapshot

  func restore() async throws -> MeetingLibrarySnapshot {
    snapshot
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    snapshot
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    snapshot
  }
}

extension AuthoritativeDirectory {
  fileprivate static func fixture(kind: AuthoritativeDirectoryKind) -> Self {
    .init(
      id: AuthoritativeDirectoryID(rawValue: "directory"),
      displayName: "Quillvault",
      kind: kind
    )
  }
}

extension MeetingIndexEntry {
  fileprivate static func fixture() -> Self {
    .init(
      id: MeetingID(rawValue: UUID(uuidString: "09C4387E-E914-4C4E-A727-3880E2ECA6F3")!),
      createdAt: Date(timeIntervalSince1970: 1_722_470_400),
      relativeDirectory: "meeting-20240801-120000",
      assets: [.recording]
    )
  }
}
