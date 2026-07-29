import Domain
import Foundation
import GRDB
import Testing

@testable import PersistenceGRDB

@Suite("GRDB recording session store")
struct GRDBRecordingSessionStoreTests {
  @Test("Active recording survives reopening the state database")
  func persistsActiveRecording() async throws {
    let fixture = try RecordingDatabaseFixture()
    let session = RecordingSession.fixture()
    let first = try GRDBRecordingSessionStore.open(at: fixture.databaseURL)
    try await first.saveActive(session)

    let reopened = try GRDBRecordingSessionStore.open(at: fixture.databaseURL)

    #expect(try await reopened.activeSession() == session)
  }

  @Test("A different active meeting cannot replace the current recording")
  func protectsActiveRecording() async throws {
    let fixture = try RecordingDatabaseFixture()
    let store = try GRDBRecordingSessionStore.open(at: fixture.databaseURL)
    let existing = RecordingSession.fixture()
    try await store.saveActive(existing)

    await #expect(throws: RecordingError.alreadyRecording) {
      try await store.saveActive(.fixture(id: UUID()))
    }
    #expect(try await store.activeSession() == existing)
  }

  @Test("Finishing valid audio atomically clears active state")
  func finishClearsActiveState() async throws {
    let fixture = try RecordingDatabaseFixture()
    let store = try GRDBRecordingSessionStore.open(at: fixture.databaseURL)
    let session = RecordingSession.fixture()
    try await store.saveActive(session)

    try await store.finish(
      session,
      audio: RecordedAudio(
        durationSeconds: 60,
        packetCount: 2_000,
        byteCount: 512_000
      )
    )

    #expect(try await store.activeSession() == nil)
  }

  @Test("Abandoning an invalid recording clears only its active lock")
  func abandonClearsActiveState() async throws {
    let fixture = try RecordingDatabaseFixture()
    let store = try GRDBRecordingSessionStore.open(at: fixture.databaseURL)
    let session = RecordingSession.fixture()
    try await store.saveActive(session)

    try await store.abandon(session)

    #expect(try await store.activeSession() == nil)
  }

  @Test("The recording state schema uses a named migration")
  func namedMigration() throws {
    let fixture = try RecordingDatabaseFixture()
    _ = try GRDBRecordingSessionStore.open(at: fixture.databaseURL)
    let queue = try DatabaseQueue(path: fixture.databaseURL.path)

    let migrationIDs = try queue.read { database in
      try String.fetchAll(
        database,
        sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
      )
    }
    #expect(migrationIDs == ["v1_create_recording_session_state"])
  }
}

private final class RecordingDatabaseFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "quillvault-recording-state-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    databaseURL = root.appending(path: "recording-state.sqlite")
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}

extension RecordingSession {
  fileprivate static func fixture(id: UUID? = nil) -> Self {
    .init(
      meetingID: MeetingID(
        rawValue: id
          ?? UUID(uuidString: "D3142EC0-989B-4925-B7DE-ACF83C092240")!
      ),
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}
