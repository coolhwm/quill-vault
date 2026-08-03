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

    #expect(try await catalog.appliedMigrations() == expectedMigrations)
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
      try await second.appliedMigrations() == expectedMigrations
    )
    #expect(try await second.meetings() == [meeting])
  }

  @Test("Migrates a populated v1 catalog without losing meeting identity")
  func migratesPopulatedV1Catalog() async throws {
    let databaseURL = temporaryDatabaseURL()
    let database = try DatabaseQueue(path: databaseURL.path)
    try MeetingCatalogMigrator.makeInitial().migrate(database)
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO meeting_index
            (meeting_id, created_at, relative_directory, asset_presence)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          "11111111-1111-1111-1111-111111111111",
          1_722_470_400,
          "meeting-20240801-120000",
          MeetingAssetPresence.recording.rawValue,
        ]
      )
    }

    let catalog = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    let meeting = try #require(await catalog.meetings().first)

    #expect(meeting.id.rawValue.uuidString == "11111111-1111-1111-1111-111111111111")
    #expect(meeting.relativeDirectory == "meeting-20240801-120000")
    #expect(meeting.title == nil)
    #expect(meeting.durationSeconds == nil)
    #expect(meeting.modelName == nil)
    #expect(try await catalog.appliedMigrations() == expectedMigrations)
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
    #expect(state.1 == expectedMigrations)
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

  @Test("Searches title, summary, and transcript with combinable filters")
  func localSearchAndFilters() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let recent = MeetingIndexEntry.fixture(
      id: "D1111111-1111-1111-1111-111111111111",
      createdAt: 1_800_000_000,
      directory: "meeting-recent",
      assets: [.recording, .transcript, .minutes],
      title: "季度复盘",
      modelName: "deepseek-chat"
    )
    let older = MeetingIndexEntry.fixture(
      id: "D2222222-2222-2222-2222-222222222222",
      createdAt: 1_700_000_000,
      directory: "meeting-older",
      assets: [.recording, .transcript],
      title: "Planning",
      modelName: nil
    )
    try await catalog.replaceAll(
      with: MeetingDirectoryScan(
        meetings: [older, recent],
        fingerprints: [],
        diagnostics: [],
        searchDocuments: [
          MeetingSearchDocument(
            meetingID: recent.id,
            title: "季度复盘",
            summary: "确认下一季度增长目标",
            transcript: "讨论华东区域投放计划"
          ),
          MeetingSearchDocument(
            meetingID: older.id,
            title: "Planning",
            summary: "Roadmap review",
            transcript: "offline first storage"
          ),
        ]
      )
    )

    #expect(try await catalog.search(.init(text: "季度")).map(\.id) == [recent.id])
    #expect(try await catalog.search(.init(text: "增长目标")).map(\.id) == [recent.id])
    #expect(try await catalog.search(.init(text: "华东区域")).map(\.id) == [recent.id])
    #expect(
      try await catalog.search(
        .init(
          createdFrom: Date(timeIntervalSince1970: 1_750_000_000),
          statuses: [.minutesCompleted],
          modelName: "DEEPSEEK-CHAT"
        )
      ).map(\.id) == [recent.id]
    )
    #expect(
      try await catalog.search(.init(statuses: [.awaitingMinutes])).map(\.id)
        == [older.id]
    )
  }

  @Test("Indexes transcript freshness and exposes expired minutes separately")
  func minutesFreshnessStatus() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let fresh = MeetingIndexEntry(
      id: MeetingID(rawValue: UUID(uuidString: "E1111111-1111-1111-1111-111111111111")!),
      createdAt: Date(timeIntervalSince1970: 1_800_000_001),
      relativeDirectory: "meeting-fresh",
      assets: [.transcript, .minutes],
      transcriptRevisionID: "revision-2",
      transcriptFingerprint: "fingerprint-2",
      minutesTranscriptRevisionID: "revision-2",
      minutesTranscriptFingerprint: "fingerprint-2",
      minutesContentFingerprint: "minutes-2"
    )
    let expired = MeetingIndexEntry(
      id: MeetingID(rawValue: UUID(uuidString: "E2222222-2222-2222-2222-222222222222")!),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: "meeting-expired",
      assets: [.transcript, .minutes],
      transcriptRevisionID: "revision-3",
      transcriptFingerprint: "fingerprint-3-new",
      minutesTranscriptRevisionID: "revision-3-old",
      minutesTranscriptFingerprint: "fingerprint-3-old",
      minutesContentFingerprint: "minutes-3"
    )
    try await catalog.replaceAll(
      with: MeetingDirectoryScan(
        meetings: [fresh, expired],
        fingerprints: [],
        diagnostics: []
      )
    )

    #expect((try await catalog.meetings()).first?.status == .minutesCompleted)
    #expect((try await catalog.meetings()).last?.status == .minutesExpired)
    #expect(
      try await catalog.search(.init(statuses: [.minutesCompleted])).map(\.id)
        == [fresh.id]
    )
    #expect(
      try await catalog.search(.init(statuses: [.minutesExpired])).map(\.id)
        == [expired.id]
    )
  }

  @Test("Metadata-stripped minutes remain readable but require regeneration")
  func metadataStrippedMinutesAreExpired() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let unknown = MeetingIndexEntry(
      id: MeetingID(rawValue: UUID(uuidString: "E3333333-3333-3333-3333-333333333333")!),
      createdAt: Date(timeIntervalSince1970: 1_800_000_002),
      relativeDirectory: "meeting-metadata-stripped",
      assets: [.transcript, .minutes],
      transcriptRevisionID: "revision-4",
      transcriptFingerprint: "fingerprint-4",
      minutesContentFingerprint: "minutes-4"
    )
    try await catalog.replaceAll(
      with: MeetingDirectoryScan(
        meetings: [unknown],
        fingerprints: [],
        diagnostics: []
      )
    )

    #expect(unknown.status == .minutesExpired)
    #expect(
      try await catalog.search(.init(statuses: [.minutesExpired])).map(\.id)
        == [unknown.id]
    )
    #expect(try await catalog.meetings() == [unknown])
  }

  @Test("FTS replacement removes deleted and externally changed content")
  func searchReplacement() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let meeting = MeetingIndexEntry.fixture(
      id: "D3333333-3333-3333-3333-333333333333"
    )
    try await catalog.replaceAll(
      with: MeetingDirectoryScan(
        meetings: [meeting],
        fingerprints: [],
        diagnostics: [],
        searchDocuments: [
          .init(
            meetingID: meeting.id,
            title: "Old title",
            summary: "",
            transcript: "legacy searchable phrase"
          )
        ]
      )
    )
    #expect(try await catalog.search(.init(text: "legacy")).count == 1)

    try await catalog.replaceAll(
      with: MeetingDirectoryScan(
        meetings: [meeting],
        fingerprints: [],
        diagnostics: [],
        searchDocuments: [
          .init(
            meetingID: meeting.id,
            title: "New title",
            summary: "",
            transcript: "replacement content"
          )
        ]
      )
    )
    #expect(try await catalog.search(.init(text: "legacy")).isEmpty)
    #expect(try await catalog.search(.init(text: "replacement")).count == 1)

    try await catalog.replaceAll(with: .empty)
    #expect(try await catalog.search(.init(text: "replacement")).isEmpty)
  }

  @Test("Incremental synchronization reindexes changed files and removes deleted meetings")
  func incrementalSynchronization() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let changed = MeetingIndexEntry.fixture(
      id: "D4444444-4444-4444-4444-444444444444",
      directory: "meeting-changed"
    )
    let deleted = MeetingIndexEntry.fixture(
      id: "D5555555-5555-5555-5555-555555555555",
      directory: "meeting-deleted"
    )
    try await catalog.replaceAll(
      with: scan(
        meetings: [changed, deleted],
        texts: [changed.id: "old searchable", deleted.id: "delete searchable"],
        digest: "v1"
      )
    )

    try await catalog.synchronize(
      with: scan(
        meetings: [changed],
        texts: [changed.id: "new searchable"],
        digest: "v2"
      )
    )

    #expect(try await catalog.search(.init(text: "old searchable")).isEmpty)
    #expect(
      try await catalog.search(.init(text: "new searchable")).map(\.id)
        == [changed.id]
    )
    #expect(try await catalog.search(.init(text: "delete searchable")).isEmpty)
    #expect(try await catalog.meetings().map(\.id) == [changed.id])
  }

  @Test("Rebuilds and searches 2,000 meetings within the local index budgets")
  func largeSearchPerformance() async throws {
    let catalog = try GRDBMeetingCatalog.openRecovering(at: temporaryDatabaseURL())
    let meetings = (0..<2_000).map { index in
      MeetingIndexEntry(
        id: MeetingID(rawValue: UUID()),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
        relativeDirectory: "meeting-\(index)",
        assets: [.transcript, .minutes],
        title: "Meeting \(index)",
        durationSeconds: 60,
        modelName: index.isMultiple(of: 2) ? "model-a" : "model-b",
        transcriptRevisionID: "revision-\(index)",
        transcriptFingerprint: "fingerprint-\(index)",
        minutesTranscriptRevisionID: "revision-\(index)",
        minutesTranscriptFingerprint: "fingerprint-\(index)",
        minutesContentFingerprint: "minutes-\(index)"
      )
    }
    let target = meetings[1_337]
    let scan = MeetingDirectoryScan(
      meetings: meetings,
      fingerprints: [],
      diagnostics: [],
      searchDocuments: meetings.enumerated().map { index, meeting in
        MeetingSearchDocument(
          meetingID: meeting.id,
          title: meeting.title ?? "",
          summary: index == 1_337 ? "unique performance needle" : "ordinary summary",
          transcript: "local transcript \(index)"
        )
      }
    )
    let clock = ContinuousClock()

    let rebuildStart = clock.now
    try await catalog.replaceAll(with: scan)
    let rebuildDuration = rebuildStart.duration(to: clock.now)
    let searchStart = clock.now
    let results = try await catalog.search(
      .init(
        text: "performance needle",
        statuses: [.minutesCompleted],
        modelName: "model-b"
      )
    )
    let searchDuration = searchStart.duration(to: clock.now)

    #expect(results.map(\.id) == [target.id])
    #expect(rebuildDuration < .seconds(60))
    #expect(searchDuration < .milliseconds(500))
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

  @Test("Runtime corruption is quarantined and leaves a rebuildable catalog")
  func runtimeCorruptionRecovery() async throws {
    let databaseURL = temporaryDatabaseURL()
    let fault = CatalogOperationFault()
    let meeting = MeetingIndexEntry.fixture(
      id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
    )
    let catalog = try GRDBMeetingCatalog.openForTesting(
      at: databaseURL,
      operationProbe: fault.check
    )
    let meetingScan = MeetingDirectoryScan(
      meetings: [meeting],
      fingerprints: [],
      diagnostics: []
    )
    try await catalog.replaceAll(with: meetingScan)
    fault.arm(.SQLITE_CORRUPT)

    #expect(try await catalog.meetings().isEmpty)
    try await catalog.replaceAll(with: meetingScan)

    #expect(try await catalog.meetings() == [meeting])
    #expect(
      try FileManager.default
        .contentsOfDirectory(
          at: databaseURL.deletingLastPathComponent(),
          includingPropertiesForKeys: nil
        )
        .contains { $0.lastPathComponent.contains(".corrupt-") }
    )
  }

  @Test("Transient database failures map to the stable catalog error")
  func databaseErrorMapping() async throws {
    let fault = CatalogOperationFault()
    let catalog = try GRDBMeetingCatalog.openForTesting(
      at: temporaryDatabaseURL(),
      operationProbe: fault.check
    )
    fault.arm(.SQLITE_BUSY)

    await #expect(throws: MeetingCatalogError.unavailable) {
      _ = try await catalog.meetings()
    }
  }

  @Test("Cancellation during a recovered retry remains cancellation")
  func recoveredRetryCancellation() async throws {
    let attempts = CatalogRecoveryAttempts()
    let catalog = try GRDBMeetingCatalog.openForTesting(
      at: temporaryDatabaseURL(),
      operationProbe: {}
    )

    await #expect(throws: CancellationError.self) {
      try await catalog.runWithRuntimeRecoveryForTesting { _ in
        try attempts.fail()
      }
    }
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

private let expectedMigrations = [
  "v1_create_rebuildable_meeting_catalog",
  "v2_add_meeting_detail_metadata",
  "v3_add_local_meeting_search",
  "v4_add_generation_freshness_metadata",
]

private enum MigrationProbeError: Error {
  case forced
}

private final class CatalogOperationFault: @unchecked Sendable {
  private let lock = NSLock()
  private var resultCode: ResultCode?

  func arm(_ resultCode: ResultCode) {
    lock.withLock {
      self.resultCode = resultCode
    }
  }

  func check() throws {
    let resultCode = lock.withLock {
      defer { self.resultCode = nil }
      return self.resultCode
    }
    if let resultCode {
      throw DatabaseError(resultCode: resultCode)
    }
  }
}

private final class CatalogRecoveryAttempts: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func fail() throws {
    let attempt = lock.withLock {
      count += 1
      return count
    }
    if attempt == 1 {
      throw DatabaseError(resultCode: .SQLITE_CORRUPT)
    }
    throw CancellationError()
  }
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

private func scan(
  meetings: [MeetingIndexEntry],
  texts: [MeetingID: String],
  digest: String
) -> MeetingDirectoryScan {
  MeetingDirectoryScan(
    meetings: meetings,
    fingerprints: meetings.map {
      MeetingFileFingerprint(
        meetingID: $0.id,
        asset: .transcript,
        byteCount: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        opaqueDigest: "\($0.id.rawValue.uuidString)-\(digest)"
      )
    },
    diagnostics: [],
    searchDocuments: meetings.map {
      MeetingSearchDocument(
        meetingID: $0.id,
        title: $0.title ?? "",
        summary: "",
        transcript: texts[$0.id] ?? ""
      )
    }
  )
}

extension MeetingIndexEntry {
  fileprivate static func fixture(
    id: String,
    createdAt: TimeInterval = 1_722_470_400,
    directory: String = "meeting-20240801-120000",
    assets: MeetingAssetPresence = [.recording, .transcript],
    title: String = "Weekly review",
    modelName: String? = "test-model"
  ) -> Self {
    let hasFreshnessMetadata =
      assets.contains(.transcript) && assets.contains(.minutes)
    return .init(
      id: MeetingID(rawValue: UUID(uuidString: id)!),
      createdAt: Date(timeIntervalSince1970: createdAt),
      relativeDirectory: directory,
      assets: assets,
      title: title,
      durationSeconds: 61,
      modelName: modelName,
      transcriptRevisionID: hasFreshnessMetadata ? "revision-\(id)" : nil,
      transcriptFingerprint: hasFreshnessMetadata ? "fingerprint-\(id)" : nil,
      minutesTranscriptRevisionID: hasFreshnessMetadata ? "revision-\(id)" : nil,
      minutesTranscriptFingerprint: hasFreshnessMetadata ? "fingerprint-\(id)" : nil,
      minutesContentFingerprint: hasFreshnessMetadata ? "minutes-\(id)" : nil
    )
  }
}
