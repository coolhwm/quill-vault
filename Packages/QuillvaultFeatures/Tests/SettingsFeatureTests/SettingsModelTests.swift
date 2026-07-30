import Application
import Domain
import Testing

@testable import SettingsFeature

@MainActor
@Suite("Settings directory model")
struct SettingsModelTests {
  @Test("Missing bookmark presents directory authorization")
  func missingBookmarkRequiresAuthorization() async {
    let model = SettingsModel(
      directory: AuthoritativeDirectoryStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkMissing)
      ),
      library: MeetingLibraryStub()
    )

    await model.load()

    #expect(model.directoryState == .recoveryRequired(.chooseDirectory))
  }

  @Test("Selecting a directory exposes the active authoritative directory")
  func selectsDirectory() async {
    let directory = AuthoritativeDirectory.fixture
    let model = SettingsModel(
      directory: AuthoritativeDirectoryStub(restoreResult: .success(directory)),
      library: MeetingLibraryStub(directory: directory)
    )

    await model.selectDirectory(opaqueReference: "file:///vault")

    #expect(model.directoryState == .authorized(directory))
  }
}

private struct MeetingLibraryStub: MeetingLibraryUseCase {
  let directory: AuthoritativeDirectory

  init(directory: AuthoritativeDirectory = .fixture) {
    self.directory = directory
  }

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

  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry] {
    snapshot.meetings
  }

  private var snapshot: MeetingLibrarySnapshot {
    MeetingLibrarySnapshot(
      directory: directory,
      meetings: [],
      diagnosticCount: 0
    )
  }
}

private struct AuthoritativeDirectoryStub: AuthoritativeDirectoryUseCase {
  let restoreResult: Result<AuthoritativeDirectory, Error>

  func restore() async throws -> AuthoritativeDirectory? {
    try restoreResult.get()
  }

  func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    try restoreResult.get()
  }
}

extension AuthoritativeDirectory {
  fileprivate static let fixture = Self(
    id: AuthoritativeDirectoryID(rawValue: "settings-test"),
    displayName: "Meeting Vault",
    kind: .userSelected
  )
}
