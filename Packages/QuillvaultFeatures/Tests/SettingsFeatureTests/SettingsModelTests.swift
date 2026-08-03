import Application
import Domain
import Foundation
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

  @Test("Loads multiple model profiles and projects the current selection")
  func loadsModelProfiles() async {
    let profiles = ModelProfileUseCaseStub(
      collection: ModelProfileCollection(
        profiles: [.fixture(name: "Fast"), .fixture(name: "Careful")],
        currentProfileID: ModelProfile.fixture(name: "Careful").id
      )
    )
    let model = SettingsModel(
      directory: AuthoritativeDirectoryStub(restoreResult: .success(.fixture)),
      library: MeetingLibraryStub(),
      modelProfiles: profiles
    )

    await model.load()

    #expect(model.modelProfiles.map(\.name) == ["Fast", "Careful"])
    #expect(model.currentModelProfileID == ModelProfile.fixture(name: "Careful").id)
  }

  @Test("A capability test exposes the provider domain without exposing its key")
  func testsModelCapability() async {
    let profile = ModelProfile.fixture(name: "Primary")
    let profiles = ModelProfileUseCaseStub(
      collection: ModelProfileCollection(
        profiles: [profile],
        currentProfileID: profile.id
      )
    )
    let model = SettingsModel(
      directory: AuthoritativeDirectoryStub(restoreResult: .success(.fixture)),
      library: MeetingLibraryStub(),
      modelProfiles: profiles
    )

    await model.testProfile(profile.id)

    #expect(
      model.profileTestState[profile.id]
        == .succeeded(providerDomain: "api.example.com")
    )
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

private actor ModelProfileUseCaseStub: ModelProfileUseCase {
  let collection: ModelProfileCollection

  init(collection: ModelProfileCollection) {
    self.collection = collection
  }

  func load() async throws -> ModelProfileCollection {
    collection
  }

  func save(_ draft: ModelProfileDraft) async throws -> ModelProfile {
    collection.profiles[0]
  }

  func select(_ id: ModelProfileID) async throws {}

  func test(_ id: ModelProfileID) async throws -> ModelCapability {
    ModelCapability(
      providerDomain: "api.example.com",
      representativeContent: true
    )
  }

  func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async throws {}

  func deletionImpact(
    _ id: ModelProfileID
  ) async throws -> ModelProfileDeletionImpact {
    .safe
  }

  func delete(_ id: ModelProfileID, confirmed: Bool) async throws {}
}

extension ModelProfile {
  fileprivate static func fixture(name: String) -> Self {
    let suffix = name == "Fast" ? "1" : name == "Careful" ? "2" : "3"
    return ModelProfile(
      id: ModelProfileID(
        rawValue: UUID(
          uuidString: "00000000-0000-0000-0000-00000000000\(suffix)"
        )!
      ),
      name: name,
      baseURL: URL(string: "https://api.example.com/v1")!,
      model: "\(name.lowercased())-model",
      credentialReference: ModelCredentialReference(rawValue: UUID()),
      isUsable: true
    )
  }
}
