import Domain
import Foundation
import GRDB

public actor GRDBRecordingSessionStore: RecordingSessionStore {
  private static let activeRowID = 1

  private let database: DatabasePool

  private init(database: DatabasePool) {
    self.database = database
  }

  public static func open(at url: URL) throws -> Self {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let database = try DatabasePool(path: url.path)
    try RecordingSessionMigrator.make().migrate(database)
    return Self(database: database)
  }

  public func activeSession() async throws -> RecordingSession? {
    try await database.read { database in
      guard
        let row = try Row.fetchOne(
          database,
          sql: """
            SELECT meeting_id, started_at
            FROM active_recording
            WHERE singleton_id = ?
            """,
          arguments: [Self.activeRowID]
        )
      else {
        return nil
      }
      guard
        let rawMeetingID = row["meeting_id"] as String?,
        let meetingID = UUID(uuidString: rawMeetingID),
        let startedAt = row["started_at"] as Date?
      else {
        throw RecordingError.statePersistenceFailed
      }
      return RecordingSession(
        meetingID: MeetingID(rawValue: meetingID),
        startedAt: startedAt
      )
    }
  }

  public func saveActive(_ session: RecordingSession) async throws {
    try await database.write { database in
      if let existing: String = try String.fetchOne(
        database,
        sql: """
          SELECT meeting_id
          FROM active_recording
          WHERE singleton_id = ?
          """,
        arguments: [Self.activeRowID]
      ) {
        guard existing == session.meetingID.rawValue.uuidString else {
          throw RecordingError.alreadyRecording
        }
        return
      }

      try database.execute(
        sql: """
          INSERT INTO active_recording (
            singleton_id,
            meeting_id,
            started_at
          ) VALUES (?, ?, ?)
          """,
        arguments: [
          Self.activeRowID,
          session.meetingID.rawValue.uuidString,
          session.startedAt,
        ]
      )
    }
  }

  public func finish(
    _ session: RecordingSession,
    audio: RecordedAudio
  ) async throws {
    guard audio.isValid else {
      throw RecordingError.invalidRecordedAudio
    }
    try await database.write { database in
      guard
        let existing: String = try String.fetchOne(
          database,
          sql: """
            SELECT meeting_id
            FROM active_recording
            WHERE singleton_id = ?
            """,
          arguments: [Self.activeRowID]
        ),
        existing == session.meetingID.rawValue.uuidString
      else {
        throw RecordingError.noActiveRecording
      }
      try database.execute(
        sql: "DELETE FROM active_recording WHERE singleton_id = ?",
        arguments: [Self.activeRowID]
      )
    }
  }

  public func abandon(_ session: RecordingSession) async throws {
    try await database.write { database in
      try database.execute(
        sql: """
          DELETE FROM active_recording
          WHERE singleton_id = ? AND meeting_id = ?
          """,
        arguments: [
          Self.activeRowID,
          session.meetingID.rawValue.uuidString,
        ]
      )
    }
  }
}

enum RecordingSessionMigrator {
  static func make() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_create_recording_session_state") { database in
      try database.create(table: "active_recording") { table in
        table.column("singleton_id", .integer)
          .primaryKey()
          .check { $0 == 1 }
        table.column("meeting_id", .text).notNull().unique()
        table.column("started_at", .datetime).notNull()
      }
    }
    return migrator
  }
}
