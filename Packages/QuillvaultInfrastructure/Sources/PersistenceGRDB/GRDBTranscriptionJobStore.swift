import Domain
import Foundation
import GRDB

public actor GRDBTranscriptionJobStore: TranscriptionJobStore {
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
    try TranscriptionJobMigrator.make().migrate(database)
    return Self(database: database)
  }

  public func savePending(_ job: TranscriptionJob) async throws {
    guard
      job.recordingURL.isFileURL,
      job.audioDurationSeconds.isFinite,
      job.audioDurationSeconds > 0,
      !job.localeIdentifier.isEmpty
    else {
      throw TranscriptError.recognitionFailed
    }
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO pending_transcription (
            meeting_id,
            recording_url,
            audio_duration_seconds,
            locale_identifier
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(meeting_id) DO UPDATE SET
            recording_url = excluded.recording_url,
            audio_duration_seconds = excluded.audio_duration_seconds,
            locale_identifier = excluded.locale_identifier
          """,
        arguments: [
          job.meetingID.rawValue.uuidString,
          job.recordingURL.absoluteString,
          job.audioDurationSeconds,
          job.localeIdentifier,
        ]
      )
    }
  }

  public func pendingJobs() async throws -> [TranscriptionJob] {
    try await database.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT
            meeting_id,
            recording_url,
            audio_duration_seconds,
            locale_identifier
          FROM pending_transcription
          ORDER BY meeting_id
          """
      )
      return try rows.map { row in
        guard
          let rawMeetingID = row["meeting_id"] as String?,
          let uuid = UUID(uuidString: rawMeetingID),
          let rawURL = row["recording_url"] as String?,
          let url = URL(string: rawURL),
          url.isFileURL,
          let duration = row["audio_duration_seconds"] as Double?,
          duration.isFinite,
          duration > 0,
          let locale = row["locale_identifier"] as String?,
          !locale.isEmpty
        else {
          throw TranscriptError.recognitionFailed
        }
        return TranscriptionJob(
          meetingID: MeetingID(rawValue: uuid),
          recordingURL: url,
          audioDurationSeconds: duration,
          localeIdentifier: locale
        )
      }
    }
  }

  public func markPublished(
    meetingID: MeetingID,
    revision: TranscriptRevision
  ) async throws {
    guard revision.meetingID == meetingID else {
      throw TranscriptError.publicationFailed
    }
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO published_transcript (
            meeting_id,
            revision_id,
            content_fingerprint,
            locale_identifier
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(meeting_id) DO UPDATE SET
            revision_id = excluded.revision_id,
            content_fingerprint = excluded.content_fingerprint,
            locale_identifier = excluded.locale_identifier
          """,
        arguments: [
          meetingID.rawValue.uuidString,
          revision.id,
          revision.contentFingerprint,
          revision.localeIdentifier,
        ]
      )
      try database.execute(
        sql: "DELETE FROM pending_transcription WHERE meeting_id = ?",
        arguments: [meetingID.rawValue.uuidString]
      )
    }
  }
}

enum TranscriptionJobMigrator {
  static let initialMigration = "v1_create_transcription_recovery_state"

  static func make() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(initialMigration) { database in
      try database.create(table: "pending_transcription") { table in
        table.column("meeting_id", .text).primaryKey()
        table.column("recording_url", .text).notNull()
        table.column("audio_duration_seconds", .double).notNull()
          .check { $0 > 0 }
        table.column("locale_identifier", .text).notNull()
      }
      try database.create(table: "published_transcript") { table in
        table.column("meeting_id", .text).primaryKey()
        table.column("revision_id", .text).notNull()
        table.column("content_fingerprint", .text).notNull()
        table.column("locale_identifier", .text).notNull()
      }
    }
    return migrator
  }
}
