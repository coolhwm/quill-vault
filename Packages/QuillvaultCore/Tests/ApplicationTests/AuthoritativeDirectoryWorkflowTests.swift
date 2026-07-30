import Application
import Domain
import Testing

@Suite("Authoritative directory workflow")
struct AuthoritativeDirectoryWorkflowTests {
  @Test("No persisted bookmark remains an explicit unauthorized state")
  func missingSelectionRemainsNil() async throws {
    let workflow = AuthoritativeDirectoryWorkflow(
      access: DirectoryAccessStub(restored: nil)
    )

    #expect(try await workflow.restore() == nil)
  }

  @Test("Authorization returns only the user-selected directory")
  func authorizesSelection() async throws {
    let directory = AuthoritativeDirectory.fixture
    let workflow = AuthoritativeDirectoryWorkflow(
      access: DirectoryAccessStub(restored: nil, authorized: directory)
    )

    let result = try await workflow.authorize(
      .init(opaqueReference: "file:///vault")
    )

    #expect(result == directory)
  }
}

private actor DirectoryAccessStub: AuthoritativeDirectoryAccess {
  let restored: AuthoritativeDirectory?
  let authorized: AuthoritativeDirectory

  init(
    restored: AuthoritativeDirectory?,
    authorized: AuthoritativeDirectory = .fixture
  ) {
    self.restored = restored
    self.authorized = authorized
  }

  func restoreSelectedDirectory() async throws -> AuthoritativeDirectory? {
    restored
  }

  func authorizeSelectedDirectory(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    authorized
  }

  func scan(
    _ directory: AuthoritativeDirectory
  ) async throws -> MeetingDirectoryScan {
    .empty
  }
}

extension AuthoritativeDirectory {
  fileprivate static let fixture = Self(
    id: AuthoritativeDirectoryID(rawValue: "directory"),
    displayName: "Vault",
    kind: .userSelected
  )
}
