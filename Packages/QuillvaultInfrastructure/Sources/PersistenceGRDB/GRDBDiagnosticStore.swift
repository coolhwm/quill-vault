import Domain
import Foundation
import GRDB

/// Bounded, local-only diagnostic storage. The table stores an encoded
/// `DiagnosticEvent`, but only after the event has been constructed from the
/// whitelisted scalar fields in Domain.
public actor GRDBDiagnosticStore: DiagnosticStore {
  public static let defaultMaximumAge: TimeInterval = 14 * 24 * 60 * 60
  public static let defaultMaximumCount = 2_000

  private let databasePool: DatabasePool
  private let maximumAge: TimeInterval
  private let maximumCount: Int
  private let now: @Sendable () -> Date

  private init(
    databasePool: DatabasePool,
    maximumAge: TimeInterval,
    maximumCount: Int,
    now: @escaping @Sendable () -> Date
  ) {
    self.databasePool = databasePool
    self.maximumAge = max(60, maximumAge)
    self.maximumCount = max(1, maximumCount)
    self.now = now
  }

  public static func open(
    at databaseURL: URL,
    maximumAge: TimeInterval = defaultMaximumAge,
    maximumCount: Int = defaultMaximumCount,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws -> GRDBDiagnosticStore {
    do {
      try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      var configuration = Configuration()
      configuration.busyMode = .timeout(5)
      let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
      var migrator = DatabaseMigrator()
      migrator.registerMigration("v1_create_diagnostic_events") { database in
        try database.create(table: "diagnostic_event") { table in
          table.column("event_id", .text).primaryKey()
          table.column("timestamp", .double).notNull()
          table.column("kind", .text).notNull()
          table.column("payload", .blob).notNull()
        }
        try database.create(
          index: "diagnostic_event_timestamp",
          on: "diagnostic_event",
          columns: ["timestamp"]
        )
      }
      try migrator.migrate(pool)
      return GRDBDiagnosticStore(
        databasePool: pool,
        maximumAge: maximumAge,
        maximumCount: maximumCount,
        now: now
      )
    } catch {
      throw DiagnosticStoreError.unavailable
    }
  }

  public func record(_ event: DiagnosticEvent) async {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let payload = try encoder.encode(event)
      try await databasePool.write { database in
        try database.execute(
          sql: """
            INSERT OR REPLACE INTO diagnostic_event
              (event_id, timestamp, kind, payload)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [
            event.id.uuidString,
            event.timestamp.timeIntervalSince1970,
            event.kind.rawValue,
            payload,
          ]
        )
        try Self.prune(
          database,
          now: now(),
          maximumAge: maximumAge,
          maximumCount: maximumCount
        )
      }
    } catch {
      // Diagnostics are observability only. A full or unavailable diagnostic
      // database must never interrupt recording, transcription or generation.
    }
  }

  public func recentEvents(limit: Int = defaultMaximumCount) async throws -> [DiagnosticEvent] {
    do {
      try await pruneExpired()
      let rows = try databasePool.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT payload FROM diagnostic_event
            ORDER BY timestamp DESC, event_id DESC
            LIMIT ?
            """,
          arguments: [min(max(0, limit), maximumCount)]
        )
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try rows.map { row in
        guard let payload: Data = row["payload"] else {
          throw DiagnosticStoreError.invalidData
        }
        return try decoder.decode(DiagnosticEvent.self, from: payload)
      }
    } catch let error as DiagnosticStoreError {
      throw error
    } catch {
      throw DiagnosticStoreError.unavailable
    }
  }

  public func diagnosticPreview() async throws -> DiagnosticPreview {
    do {
      try await pruneExpired()
      let result = try databasePool.read { database in
        try Row.fetchOne(
          database,
          sql: """
            SELECT COUNT(*) AS event_count,
                   MIN(timestamp) AS oldest_timestamp,
                   MAX(timestamp) AS newest_timestamp
            FROM diagnostic_event
            """
        )
      }
      let count: Int = result?["event_count"] ?? 0
      let oldest: Double? = result?["oldest_timestamp"]
      let newest: Double? = result?["newest_timestamp"]
      return DiagnosticPreview(
        eventCount: count,
        oldestEventAt: oldest.map(Date.init(timeIntervalSince1970:)),
        newestEventAt: newest.map(Date.init(timeIntervalSince1970:)),
        retentionDays: Int(maximumAge / (24 * 60 * 60))
      )
    } catch {
      throw DiagnosticStoreError.unavailable
    }
  }

  public func exportPackage() async throws -> DiagnosticExportPackage {
    let events = try await recentEvents(limit: maximumCount).sorted {
      if $0.timestamp == $1.timestamp { return $0.id.uuidString < $1.id.uuidString }
      return $0.timestamp < $1.timestamp
    }
    return DiagnosticExportPackage(
      retentionDays: Int(maximumAge / (24 * 60 * 60)),
      events: events
    )
  }

  private func pruneExpired() async throws {
    try await databasePool.write { database in
      try Self.prune(
        database,
        now: now(),
        maximumAge: maximumAge,
        maximumCount: maximumCount
      )
    }
  }

  private static func prune(
    _ database: Database,
    now: Date,
    maximumAge: TimeInterval,
    maximumCount: Int
  ) throws {
    let cutoff = now.timeIntervalSince1970 - maximumAge
    try database.execute(
      sql: "DELETE FROM diagnostic_event WHERE timestamp < ?",
      arguments: [cutoff]
    )
    try database.execute(
      sql: """
        DELETE FROM diagnostic_event
        WHERE event_id NOT IN (
          SELECT event_id FROM diagnostic_event
          ORDER BY timestamp DESC, event_id DESC
          LIMIT ?
        )
        """,
      arguments: [maximumCount]
    )
  }
}
