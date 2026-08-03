import Application
import Domain
import Foundation
import Testing

@testable import ProfileFeature

@MainActor
@Suite("Profile model")
struct ProfileModelTests {
  @Test("Loads stats from the meeting library snapshot")
  func loadsStats() async {
    let meetings = [
      MeetingIndexEntry(
        id: MeetingID(
          rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        ),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        relativeDirectory: "m1",
        assets: [.recording, .transcript],
        durationSeconds: 300
      )
    ]
    let model = ProfileModel(
      library: LibraryStub(meetings: meetings),
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    await model.load()
    #expect(model.stats.meetingCount == 1)
    #expect(model.stats.totalDurationSeconds == 300)
    #expect(!model.loadFailed)
  }
}

private struct LibraryStub: MeetingLibraryUseCase {
  let meetings: [MeetingIndexEntry]

  func restore() async throws -> MeetingLibrarySnapshot {
    MeetingLibrarySnapshot(
      directory: AuthoritativeDirectory(
        id: AuthoritativeDirectoryID(rawValue: "profile-test"),
        displayName: "Vault",
        kind: .userSelected
      ),
      meetings: meetings,
      diagnosticCount: 0
    )
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  func synchronize() async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry] {
    meetings
  }
}
