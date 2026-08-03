import GRDB

enum MeetingCatalogMigrator {
  static let initialMigration = "v1_create_rebuildable_meeting_catalog"
  static let detailMetadataMigration = "v2_add_meeting_detail_metadata"
  static let localSearchMigration = "v3_add_local_meeting_search"
  static let generationFreshnessMigration = "v4_add_generation_freshness_metadata"

  static func make() -> DatabaseMigrator {
    var migrator = makeInitial()
    migrator.registerMigration(detailMetadataMigration) { database in
      try database.alter(table: "meeting_index") { table in
        table.add(column: "title", .text)
        table.add(column: "duration_seconds", .double)
        table.add(column: "model_name", .text)
      }
    }
    migrator.registerMigration(localSearchMigration) { database in
      try database.create(virtualTable: "meeting_search", using: FTS5()) { table in
        table.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
        table.column("meeting_id").notIndexed()
        table.column("title")
        table.column("summary")
        table.column("transcript")
      }
    }
    migrator.registerMigration(generationFreshnessMigration) { database in
      try database.alter(table: "meeting_index") { table in
        table.add(column: "transcript_revision_id", .text)
        table.add(column: "transcript_fingerprint", .text)
        table.add(column: "minutes_transcript_revision_id", .text)
        table.add(column: "minutes_transcript_fingerprint", .text)
        table.add(column: "minutes_content_fingerprint", .text)
        table.add(column: "minutes_generation_job_id", .text)
      }
    }
    return migrator
  }

  static func makeInitial() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(initialMigration) { database in
      try database.create(table: "meeting_index") { table in
        table.column("meeting_id", .text).primaryKey()
        table.column("created_at", .double).notNull()
        table.column("relative_directory", .text).notNull().unique()
        table.column("asset_presence", .integer).notNull()
      }
      try database.create(table: "meeting_file_fingerprint") { table in
        table.column("meeting_id", .text).notNull()
          .references("meeting_index", onDelete: .cascade)
        table.column("asset", .text).notNull()
        table.column("byte_count", .integer).notNull()
        table.column("modified_at", .double).notNull()
        table.column("opaque_digest", .text).notNull()
        table.primaryKey(["meeting_id", "asset"])
      }
      try database.create(table: "meeting_scan_diagnostic") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("code", .text).notNull()
        table.column("relative_path_digest", .text).notNull()
      }
      try database.create(table: "schema_metadata") { table in
        table.column("key", .text).primaryKey()
        table.column("value", .text).notNull()
      }
      try database.execute(
        sql: """
          INSERT INTO schema_metadata (key, value)
          VALUES ('content_authority', 'meeting-files')
          """
      )
    }
    return migrator
  }
}
