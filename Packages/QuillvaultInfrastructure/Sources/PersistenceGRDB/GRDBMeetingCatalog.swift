import Domain
import Foundation
import GRDB

public actor GRDBMeetingCatalog: MeetingCatalog, MeetingSearchCatalog {
  private let databaseURL: URL
  private var databasePool: DatabasePool
  private let operationProbe: @Sendable () throws -> Void

  private init(
    databaseURL: URL,
    databasePool: DatabasePool,
    operationProbe: @escaping @Sendable () throws -> Void = {}
  ) {
    self.databaseURL = databaseURL
    self.databasePool = databasePool
    self.operationProbe = operationProbe
  }

  public static func openRecovering(
    at databaseURL: URL
  ) throws -> GRDBMeetingCatalog {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    do {
      return try open(at: databaseURL)
    } catch {
      guard shouldQuarantine(error) else {
        throw MeetingCatalogError.unavailable
      }
      try quarantineDatabaseFiles(at: databaseURL, fileManager: fileManager)
      do {
        return try open(at: databaseURL)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw MeetingCatalogError.unavailable
      }
    }
  }

  static func openForTesting(
    at databaseURL: URL,
    operationProbe: @escaping @Sendable () throws -> Void
  ) throws -> GRDBMeetingCatalog {
    GRDBMeetingCatalog(
      databaseURL: databaseURL,
      databasePool: try openDatabasePool(at: databaseURL),
      operationProbe: operationProbe
    )
  }

  func runWithRuntimeRecoveryForTesting(
    _ operation: @Sendable (DatabasePool) async throws -> Void
  ) async throws {
    try await withRuntimeRecovery(operation)
  }

  public func replaceAll(with scan: MeetingDirectoryScan) async throws {
    try await withRuntimeRecovery { databasePool in
      try await databasePool.write { database in
        try database.execute(sql: "DELETE FROM meeting_scan_diagnostic")
        try database.execute(sql: "DELETE FROM meeting_file_fingerprint")
        try database.execute(sql: "DELETE FROM meeting_search")
        try database.execute(sql: "DELETE FROM meeting_index")

        for meeting in scan.meetings {
          try Self.upsertMeeting(meeting, in: database)
        }
        try Self.replaceFingerprints(scan.fingerprints, in: database)
        try Self.replaceDiagnostics(scan.diagnostics, in: database)
        try Self.replaceSearchDocuments(scan.searchDocuments, in: database)
      }
    }
  }

  public func synchronize(with scan: MeetingDirectoryScan) async throws {
    try await withRuntimeRecovery { databasePool in
      try await databasePool.write { database in
        let existingMeetingIDs = Set(
          try String.fetchAll(database, sql: "SELECT meeting_id FROM meeting_index")
        )
        let existingFingerprints = Dictionary(
          uniqueKeysWithValues: try Row.fetchAll(
            database,
            sql: """
              SELECT meeting_id, asset, opaque_digest
              FROM meeting_file_fingerprint
              """
          ).map { row in
            let meetingID: String = row["meeting_id"]
            let asset: String = row["asset"]
            let digest: String = row["opaque_digest"]
            return ("\(meetingID)|\(asset)", digest)
          }
        )
        let scannedFingerprints = Dictionary(
          uniqueKeysWithValues: scan.fingerprints.map {
            (
              "\($0.meetingID.rawValue.uuidString)|\($0.asset.rawValue)",
              $0.opaqueDigest
            )
          }
        )
        var changedMeetingIDs = Set(
          scan.meetings
            .map { $0.id.rawValue.uuidString }
            .filter { !existingMeetingIDs.contains($0) }
        )
        for key in Set(existingFingerprints.keys).union(scannedFingerprints.keys)
        where existingFingerprints[key] != scannedFingerprints[key] {
          if let separator = key.firstIndex(of: "|") {
            changedMeetingIDs.insert(String(key[..<separator]))
          }
        }

        let scannedMeetingIDs = Set(scan.meetings.map { $0.id.rawValue.uuidString })
        for removedID in existingMeetingIDs.subtracting(scannedMeetingIDs) {
          try database.execute(
            sql: "DELETE FROM meeting_search WHERE meeting_id = ?",
            arguments: [removedID]
          )
          try database.execute(
            sql: "DELETE FROM meeting_index WHERE meeting_id = ?",
            arguments: [removedID]
          )
        }

        for meeting in scan.meetings {
          try Self.upsertMeeting(meeting, in: database)
        }

        try Self.replaceFingerprints(scan.fingerprints, in: database)

        let documents = Dictionary(
          uniqueKeysWithValues: scan.searchDocuments.map {
            ($0.meetingID.rawValue.uuidString, $0)
          }
        )
        for meetingID in changedMeetingIDs {
          try database.execute(
            sql: "DELETE FROM meeting_search WHERE meeting_id = ?",
            arguments: [meetingID]
          )
          if let document = documents[meetingID] {
            try Self.insertSearchDocument(document, in: database)
          }
        }

        try Self.replaceDiagnostics(scan.diagnostics, in: database)
      }
    }
  }

  public func meetings() async throws -> [MeetingIndexEntry] {
    try await withRuntimeRecovery { databasePool in
      try await databasePool.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT
              meeting_id, created_at, relative_directory, asset_presence,
              title, duration_seconds, model_name
            FROM meeting_index
            ORDER BY created_at DESC, meeting_id ASC
            """
        ).map(Self.decodeMeeting)
      }
    }
  }

  public func search(
    _ query: MeetingSearchQuery
  ) async throws -> [MeetingIndexEntry] {
    try await withRuntimeRecovery { databasePool in
      try await databasePool.read { database in
        var predicates: [String] = []
        var arguments: StatementArguments = []
        let hasText = !query.text.isEmpty

        if hasText {
          if query.text.count >= 3 {
            predicates.append("meeting_search MATCH ?")
            arguments += [Self.ftsLiteral(query.text)]
          } else {
            predicates.append(
              """
              (
                s.title LIKE ? ESCAPE '\\' OR
                s.summary LIKE ? ESCAPE '\\' OR
                s.transcript LIKE ? ESCAPE '\\'
              )
              """
            )
            let pattern = "%\(Self.likeLiteral(query.text))%"
            arguments += [pattern, pattern, pattern]
          }
        }
        if let createdFrom = query.createdFrom {
          predicates.append("i.created_at >= ?")
          arguments += [createdFrom.timeIntervalSince1970]
        }
        if let createdThrough = query.createdThrough {
          predicates.append("i.created_at <= ?")
          arguments += [createdThrough.timeIntervalSince1970]
        }
        if let modelName = query.modelName, !modelName.isEmpty {
          predicates.append("i.model_name = ? COLLATE NOCASE")
          arguments += [modelName]
        }
        if !query.statuses.isEmpty {
          let statusPredicates = query.statuses.map(Self.statusPredicate)
          predicates.append(
            "(\(statusPredicates.map(\.sql).joined(separator: " OR ")))"
          )
          for statusPredicate in statusPredicates {
            arguments += statusPredicate.arguments
          }
        }

        let join =
          hasText
          ? "JOIN meeting_search s ON s.meeting_id = i.meeting_id"
          : ""
        let whereClause =
          predicates.isEmpty
          ? ""
          : "WHERE \(predicates.joined(separator: " AND "))"
        return try Row.fetchAll(
          database,
          sql: """
            SELECT
              i.meeting_id, i.created_at, i.relative_directory, i.asset_presence,
              i.title, i.duration_seconds, i.model_name
            FROM meeting_index i
            \(join)
            \(whereClause)
            ORDER BY i.created_at DESC, i.meeting_id ASC
            """,
          arguments: arguments
        ).map(Self.decodeMeeting)
      }
    }
  }

  public func appliedMigrations() async throws -> [String] {
    try await withRuntimeRecovery { databasePool in
      try await databasePool.read { database in
        try String.fetchAll(
          database,
          sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
        )
      }
    }
  }

  public func journalMode() async throws -> String {
    try await withRuntimeRecovery { databasePool in
      try await databasePool.read { database in
        try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
      }
    }
  }

  public func close() async throws {
    try databasePool.close()
  }

  private static func open(
    at databaseURL: URL
  ) throws -> GRDBMeetingCatalog {
    GRDBMeetingCatalog(
      databaseURL: databaseURL,
      databasePool: try openDatabasePool(at: databaseURL)
    )
  }

  private static func openDatabasePool(
    at databaseURL: URL
  ) throws -> DatabasePool {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)

    let pool = try DatabasePool(
      path: databaseURL.path,
      configuration: configuration
    )
    let migrator = MeetingCatalogMigrator.make()
    try migrator.migrate(pool)
    try pool.read { database in
      _ = try Int.fetchOne(database, sql: "PRAGMA schema_version")
      let contentAuthority = try String.fetchOne(
        database,
        sql: """
          SELECT value FROM schema_metadata
          WHERE key = 'content_authority'
          """
      )
      guard contentAuthority == "meeting-files" else {
        throw DatabaseError(
          resultCode: .SQLITE_CORRUPT,
          message: "Rebuildable catalog schema metadata is invalid"
        )
      }
    }
    return pool
  }

  private static func decodeMeeting(_ row: Row) throws -> MeetingIndexEntry {
    let identifier: String = row["meeting_id"]
    guard let uuid = UUID(uuidString: identifier) else {
      throw DatabaseError(
        resultCode: .SQLITE_CORRUPT,
        message: "Invalid meeting identifier in rebuildable index"
      )
    }
    let createdAt: Double = row["created_at"]
    let rawAssetPresence: UInt8 = row["asset_presence"]
    return MeetingIndexEntry(
      id: MeetingID(rawValue: uuid),
      createdAt: Date(timeIntervalSince1970: createdAt),
      relativeDirectory: row["relative_directory"],
      assets: MeetingAssetPresence(rawValue: rawAssetPresence),
      title: row["title"],
      durationSeconds: row["duration_seconds"],
      modelName: row["model_name"]
    )
  }

  private static func statusPredicate(
    _ status: MeetingIndexStatus
  ) -> (sql: String, arguments: StatementArguments) {
    let transcriptMask = MeetingAssetPresence.transcript.rawValue
    let minutesMask = MeetingAssetPresence.minutes.rawValue
    switch status {
    case .awaitingTranscript:
      return ("(i.asset_presence & ?) = 0", [transcriptMask])
    case .awaitingMinutes:
      return (
        "(i.asset_presence & ?) != 0 AND (i.asset_presence & ?) = 0",
        [transcriptMask, minutesMask]
      )
    case .minutesCompleted:
      return ("(i.asset_presence & ?) != 0", [minutesMask])
    }
  }

  private func withRuntimeRecovery<Value: Sendable>(
    _ operation: @Sendable (DatabasePool) async throws -> Value
  ) async throws -> Value {
    do {
      try operationProbe()
      return try await operation(databasePool)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard Self.shouldQuarantine(error) else {
        throw MeetingCatalogError.unavailable
      }
      do {
        try databasePool.close()
        try Self.quarantineDatabaseFiles(
          at: databaseURL,
          fileManager: .default
        )
        let recoveredPool = try Self.openDatabasePool(at: databaseURL)
        databasePool = recoveredPool
        do {
          return try await operation(recoveredPool)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw MeetingCatalogError.unavailable
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw MeetingCatalogError.unavailable
      }
    }
  }

  private static func upsertMeeting(
    _ meeting: MeetingIndexEntry,
    in database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO meeting_index
          (
            meeting_id, created_at, relative_directory, asset_presence,
            title, duration_seconds, model_name
          )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(meeting_id) DO UPDATE SET
          created_at = excluded.created_at,
          relative_directory = excluded.relative_directory,
          asset_presence = excluded.asset_presence,
          title = excluded.title,
          duration_seconds = excluded.duration_seconds,
          model_name = excluded.model_name
        """,
      arguments: [
        meeting.id.rawValue.uuidString,
        meeting.createdAt.timeIntervalSince1970,
        meeting.relativeDirectory,
        meeting.assets.rawValue,
        meeting.title,
        meeting.durationSeconds,
        meeting.modelName,
      ]
    )
  }

  private static func replaceFingerprints(
    _ fingerprints: [MeetingFileFingerprint],
    in database: Database
  ) throws {
    try database.execute(sql: "DELETE FROM meeting_file_fingerprint")
    for fingerprint in fingerprints {
      try database.execute(
        sql: """
          INSERT INTO meeting_file_fingerprint
            (meeting_id, asset, byte_count, modified_at, opaque_digest)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          fingerprint.meetingID.rawValue.uuidString,
          fingerprint.asset.rawValue,
          fingerprint.byteCount,
          fingerprint.modifiedAt.timeIntervalSince1970,
          fingerprint.opaqueDigest,
        ]
      )
    }
  }

  private static func replaceDiagnostics(
    _ diagnostics: [MeetingScanDiagnostic],
    in database: Database
  ) throws {
    try database.execute(sql: "DELETE FROM meeting_scan_diagnostic")
    for diagnostic in diagnostics {
      try database.execute(
        sql: """
          INSERT INTO meeting_scan_diagnostic (code, relative_path_digest)
          VALUES (?, ?)
          """,
        arguments: [diagnostic.code.rawValue, diagnostic.relativePathDigest]
      )
    }
  }

  private static func replaceSearchDocuments(
    _ documents: [MeetingSearchDocument],
    in database: Database
  ) throws {
    for document in documents {
      try insertSearchDocument(document, in: database)
    }
  }

  private static func insertSearchDocument(
    _ document: MeetingSearchDocument,
    in database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO meeting_search
          (meeting_id, title, summary, transcript)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [
        document.meetingID.rawValue.uuidString,
        document.title,
        document.summary,
        document.transcript,
      ]
    )
  }

  private static func ftsLiteral(_ text: String) -> String {
    "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func likeLiteral(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private static func quarantineDatabaseFiles(
    at databaseURL: URL,
    fileManager: FileManager
  ) throws {
    let suffix = ".corrupt-\(UUID().uuidString)"
    for url in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where fileManager.fileExists(atPath: url.path) {
      try fileManager.moveItem(
        at: url,
        to: URL(fileURLWithPath: url.path + suffix)
      )
    }
  }

  static func shouldQuarantine(_ error: Error) -> Bool {
    guard let databaseError = error as? DatabaseError else {
      return false
    }
    return databaseError.resultCode == .SQLITE_CORRUPT
      || databaseError.resultCode == .SQLITE_NOTADB
  }
}
