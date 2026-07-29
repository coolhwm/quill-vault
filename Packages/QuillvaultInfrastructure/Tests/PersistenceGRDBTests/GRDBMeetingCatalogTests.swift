import Domain
import Foundation
import GRDB
import Testing

@testable import PersistenceGRDB

@Suite("GRDB meeting catalog")
struct GRDBMeetingCatalogTests {
  @Test("Runs named migrations and enables WAL")
  func migrationAndWAL() async throws {
    let databaseURL = temporaryDatabaseURL()
    let catalog = try GRDBMeetingCatalog.openRecovering(at: databaseURL)

    #expect(try await catalog.appliedMigrations() == ["v1_create_rebuildable_meeting_catalog"])
    #expect(try await catalog.journalMode().lowercased() == "wal")
  }

  @Test("Repeated startup does not rerun completed migrations")
  func repeatedStartup() async throws {
    let databaseURL = temporaryDatabaseURL()
    let meeting = MeetingIndexEntry.fixture(id: "11111111-1111-1111-1111-111111111111")
    let first = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    try await first.replaceAll(
      with: MeetingDirectoryScan(meetings: [meeting], fingerprints: [], diagnostics: [])
    )
    try await first.close()

    let second = try GRDBMeetingCatalog.openRecovering(at: databaseURL)

    #expect(
      try await second.appliedMigrations()
        == ["v1_create_rebuildable_meeting_catalog"]
    )
    #expect(try await second.meetings() == [meeting])
  }

  @Test("A failed migration rolls back its schema and migration marker")
  func failedMigrationRollsBack() throws {
    let database = try DatabaseQueue(path: temporaryDatabaseURL().path)
    var migrator = MeetingCatalogMigrator.make()
    migrator.registerMigration("v2_forced_failure") { database in
      try database.create(table: "partial_migration") { table in
        table.column("id", .integer)
      }
      throw MigrationProbeError.forced
    }

    #expect(throws: MigrationProbeError.forced) {
      try migrator.migrate(database)
    }
    let state = try database.read { database in
      (
        try database.tableExists("partial_migration"),
        try String.fetchAll(
          database,
          sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
        )
      )
    }
    #expect(!state.0)
    #expect(state.1 == ["v1_create_rebuildable_meeting_catalog"])
  }

  @Test("WAL readers observe only complete snapshots during replacement")
  func concurrentWALReads() async throws {
    let databaseURL = temporaryDatabaseURL()
    let writer = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    let reader = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    let meeting = MeetingIndexEntry.fixture(id: "22222222-2222-2222-2222-222222222222")
    let scan = MeetingDirectoryScan(
      meetings: [meeting],
      fingerprints: [],
      diagnostics: []
    )
    try await writer.replaceAll(with: scan)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask {
          try await writer.replaceAll(with: scan)
        }
        group.addTask {
          let meetings = try await reader.meetings()
          #expect(meetings == [meeting])
        }
      }
      try await group.waitForAll()
    }
  }

  @Test("Replaces the complete index transactionally")
  func atomicReplacement() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let original = MeetingIndexEntry.fixture(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    try await catalog.replaceAll(
      with: MeetingDirectoryScan(meetings: [original], fingerprints: [], diagnostics: [])
    )
    let duplicatePath = MeetingIndexEntry.fixture(
      id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    )

    await #expect(throws: (any Error).self) {
      try await catalog.replaceAll(
        with: MeetingDirectoryScan(
          meetings: [original, duplicatePath],
          fingerprints: [],
          diagnostics: []
        )
      )
    }

    #expect(try await catalog.meetings() == [original])
  }

  @Test("A deleted database rebuild preserves file-owned meeting IDs")
  func deletedDatabaseRebuild() async throws {
    let databaseURL = temporaryDatabaseURL()
    let meeting = MeetingIndexEntry.fixture(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    do {
      let catalog = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
      try await catalog.replaceAll(
        with: MeetingDirectoryScan(meetings: [meeting], fingerprints: [], diagnostics: [])
      )
      try await catalog.close()
    }
    try FileManager.default.removeItem(at: databaseURL)

    let rebuilt = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    try await rebuilt.replaceAll(
      with: MeetingDirectoryScan(meetings: [meeting], fingerprints: [], diagnostics: [])
    )

    #expect(try await rebuilt.meetings().map(\.id) == [meeting.id])
  }

  @Test("A corrupt database is quarantined before a fresh rebuild")
  func corruptDatabaseRecovery() async throws {
    let databaseURL = temporaryDatabaseURL()
    try Data("not sqlite".utf8).write(to: databaseURL)

    let catalog = try GRDBMeetingCatalog.openRecovering(at: databaseURL)

    #expect(try await catalog.meetings().isEmpty)
    #expect(
      try FileManager.default
        .contentsOfDirectory(
          at: databaseURL.deletingLastPathComponent(),
          includingPropertiesForKeys: nil
        )
        .contains { $0.lastPathComponent.contains(".corrupt-") }
    )
  }

  @Test("Transient and migration errors never trigger corruption quarantine")
  func quarantineClassification() {
    #expect(
      !GRDBMeetingCatalog.shouldQuarantine(
        DatabaseError(resultCode: .SQLITE_BUSY)
      )
    )
    #expect(
      !GRDBMeetingCatalog.shouldQuarantine(
        DatabaseError(resultCode: .SQLITE_ERROR)
      )
    )
    #expect(
      !GRDBMeetingCatalog.shouldQuarantine(MigrationProbeError.forced)
    )
    #expect(
      GRDBMeetingCatalog.shouldQuarantine(
        DatabaseError(resultCode: .SQLITE_CORRUPT)
      )
    )
  }
}

private enum MigrationProbeError: Error {
  case forced
}

private func temporaryDatabaseURL() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "quillvault-\(UUID().uuidString)", directoryHint: .isDirectory)
  try! FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return directory.appending(path: "catalog.sqlite")
}

extension MeetingIndexEntry {
  fileprivate static func fixture(id: String) -> Self {
    .init(
      id: MeetingID(rawValue: UUID(uuidString: id)!),
      createdAt: Date(timeIntervalSince1970: 1_722_470_400),
      relativeDirectory: "meeting-20240801-120000",
      assets: [.recording, .transcript]
    )
  }
}
