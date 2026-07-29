import Domain
import Foundation
import GRDB

public actor GRDBMeetingCatalog: MeetingCatalog {
  private let databasePool: DatabasePool

  private init(databasePool: DatabasePool) {
    self.databasePool = databasePool
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
        throw error
      }
      try quarantineDatabaseFiles(at: databaseURL, fileManager: fileManager)
      return try open(at: databaseURL)
    }
  }

  public func replaceAll(with scan: MeetingDirectoryScan) async throws {
    try await databasePool.write { database in
      try database.execute(sql: "DELETE FROM meeting_scan_diagnostic")
      try database.execute(sql: "DELETE FROM meeting_file_fingerprint")
      try database.execute(sql: "DELETE FROM meeting_index")

      for meeting in scan.meetings {
        try database.execute(
          sql: """
            INSERT INTO meeting_index
              (meeting_id, created_at, relative_directory, asset_presence)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [
            meeting.id.rawValue.uuidString,
            meeting.createdAt.timeIntervalSince1970,
            meeting.relativeDirectory,
            meeting.assets.rawValue,
          ]
        )
      }
      for fingerprint in scan.fingerprints {
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
      for diagnostic in scan.diagnostics {
        try database.execute(
          sql: """
            INSERT INTO meeting_scan_diagnostic (code, relative_path_digest)
            VALUES (?, ?)
            """,
          arguments: [
            diagnostic.code.rawValue,
            diagnostic.relativePathDigest,
          ]
        )
      }
    }
  }

  public func meetings() async throws -> [MeetingIndexEntry] {
    try await databasePool.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT meeting_id, created_at, relative_directory, asset_presence
          FROM meeting_index
          ORDER BY created_at DESC, meeting_id ASC
          """
      ).map { row in
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
          assets: MeetingAssetPresence(rawValue: rawAssetPresence)
        )
      }
    }
  }

  public func appliedMigrations() async throws -> [String] {
    try await databasePool.read { database in
      try String.fetchAll(
        database,
        sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
      )
    }
  }

  public func journalMode() async throws -> String {
    try await databasePool.read { database in
      try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
    }
  }

  public func close() async throws {
    try databasePool.close()
  }

  private static func open(
    at databaseURL: URL
  ) throws -> GRDBMeetingCatalog {
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
    return GRDBMeetingCatalog(databasePool: pool)
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
