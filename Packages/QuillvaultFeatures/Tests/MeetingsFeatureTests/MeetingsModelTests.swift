import Application
import Domain
import Testing

@testable import MeetingsFeature

@MainActor
@Suite("Meetings model")
struct MeetingsModelTests {
  @Test("Loads the cold-start library snapshot")
  func loadsSnapshot() async {
    let snapshot = MeetingLibrarySnapshot.fixture
    let model = MeetingsModel(
      library: MeetingLibraryUseCaseStub(restoreResult: .success(snapshot))
    )

    await model.load()

    #expect(model.state == .loaded(snapshot))
  }

  @Test(
    "Maps a stale bookmark to explicit reauthorization instead of another directory"
  )
  func staleBookmarkRecovery() async {
    let model = MeetingsModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkStale)
      )
    )

    await model.load()

    #expect(model.state == .failed(.renewAccess))
  }

  @Test("Maps a missing bookmark to initial directory selection")
  func missingBookmarkRecovery() async {
    let model = MeetingsModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkMissing)
      )
    )

    await model.load()

    #expect(model.state == .failed(.chooseDirectory))
  }

  @Test("Maps an unavailable iCloud item to a download recovery")
  func iCloudDownloadRecovery() async {
    let model = MeetingsModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.itemNotDownloaded)
      )
    )

    await model.load()

    #expect(model.state == .failed(.downloadRequired))
  }
}

private struct MeetingLibraryUseCaseStub: MeetingLibraryUseCase {
  let restoreResult: Result<MeetingLibrarySnapshot, Error>

  func restore() async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }
}

extension MeetingLibrarySnapshot {
  fileprivate static let fixture = Self(
    directory: AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "test"),
      displayName: "Vault",
      kind: .userSelected
    ),
    meetings: [],
    diagnosticCount: 0
  )
}
