import Domain
import Foundation
import GRDB

public actor GRDBModelProfileStore:
  ModelProfileStore, ModelProfileUsageTracking
{
  private let databasePool: DatabasePool

  private init(databasePool: DatabasePool) {
    self.databasePool = databasePool
  }

  public static func open(
    at databaseURL: URL
  ) throws -> GRDBModelProfileStore {
    do {
      try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let databasePool = try DatabasePool(path: databaseURL.path)
      var migrator = DatabaseMigrator()
      migrator.registerMigration("v1_create_model_profiles") { database in
        try database.create(table: "model_profile") { table in
          table.column("profile_id", .text).primaryKey()
          table.column("name", .text).notNull()
          table.column("base_url", .text).notNull()
          table.column("model", .text).notNull()
          table.column("temperature", .double).notNull()
          table.column("maximum_output_tokens", .integer).notNull()
          table.column("uses_streaming", .boolean).notNull()
          table.column("credential_reference", .text).notNull()
          table.column("sort_order", .integer).notNull()
        }
        try database.create(table: "model_profile_selection") { table in
          table.column("singleton", .integer).primaryKey()
          table.column("profile_id", .text)
        }
      }
      migrator.registerMigration("v2_model_capability_and_generation") {
        database in
        try database.alter(table: "model_profile") { table in
          table.add(column: "is_usable", .boolean)
            .notNull()
            .defaults(to: false)
        }
        try database.create(table: "model_generation_preferences") { table in
          table.column("singleton", .integer).primaryKey()
          table.column("is_enabled", .boolean).notNull()
          table.column("disclosure_acknowledged", .boolean).notNull()
        }
        try database.create(table: "model_profile_usage") { table in
          table.column("task_reference", .text).primaryKey()
          table.column("profile_id", .text).notNull().indexed()
        }
      }
      migrator.registerMigration("v3_transcript_quality_preferences") {
        database in
        try database.create(table: "transcript_quality_preferences") { table in
          table.column("singleton", .integer).primaryKey()
          table.column("is_enabled", .boolean).notNull()
        }
      }
      try migrator.migrate(databasePool)
      return GRDBModelProfileStore(databasePool: databasePool)
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func loadAll() async throws -> [ModelProfile] {
    do {
      return try await databasePool.read { database in
        try Row.fetchAll(
          database,
          sql: "SELECT * FROM model_profile ORDER BY sort_order, profile_id"
        ).map(Self.profile)
      }
    } catch let error as ModelProfileStoreError {
      throw error
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func save(_ profile: ModelProfile) async throws {
    do {
      try await databasePool.write { database in
        let sortOrder =
          try Int.fetchOne(
            database,
            sql: """
              SELECT sort_order
              FROM model_profile
              WHERE profile_id = ?
              """,
            arguments: [profile.id.rawValue.uuidString]
          )
          ?? ((try Int.fetchOne(
            database,
            sql: "SELECT MAX(sort_order) FROM model_profile"
          ) ?? -1) + 1)
        try database.execute(
          sql: """
            INSERT INTO model_profile
              (
                profile_id, name, base_url, model, temperature,
                maximum_output_tokens, uses_streaming,
                credential_reference, sort_order, is_usable
              )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile_id) DO UPDATE SET
              name = excluded.name,
              base_url = excluded.base_url,
              model = excluded.model,
              temperature = excluded.temperature,
              maximum_output_tokens = excluded.maximum_output_tokens,
              uses_streaming = excluded.uses_streaming,
              credential_reference = excluded.credential_reference,
              is_usable = excluded.is_usable
            """,
          arguments: [
            profile.id.rawValue.uuidString,
            profile.name,
            profile.baseURL.absoluteString,
            profile.model,
            profile.parameters.temperature,
            profile.parameters.maximumOutputTokens,
            profile.parameters.usesStreaming,
            profile.credentialReference.rawValue.uuidString,
            sortOrder,
            profile.isUsable,
          ]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func currentProfileID() async throws -> ModelProfileID? {
    do {
      return try await databasePool.read { database in
        guard
          let rawValue = try String.fetchOne(
            database,
            sql: """
              SELECT profile_id
              FROM model_profile_selection
              WHERE singleton = 1
              """
          )
        else {
          return nil
        }
        guard let uuid = UUID(uuidString: rawValue) else {
          throw ModelProfileStoreError.invalidData
        }
        return ModelProfileID(rawValue: uuid)
      }
    } catch let error as ModelProfileStoreError {
      throw error
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func setCurrentProfileID(
    _ id: ModelProfileID?
  ) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: """
            INSERT INTO model_profile_selection (singleton, profile_id)
            VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET
              profile_id = excluded.profile_id
            """,
          arguments: [id?.rawValue.uuidString]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func automaticGenerationPreferences() async throws
    -> AutomaticGenerationPreferences
  {
    do {
      return try await databasePool.read { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT is_enabled, disclosure_acknowledged
              FROM model_generation_preferences
              WHERE singleton = 1
              """
          )
        else {
          return AutomaticGenerationPreferences()
        }
        return AutomaticGenerationPreferences(
          isEnabled: row["is_enabled"],
          disclosureAcknowledged: row["disclosure_acknowledged"]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func setAutomaticGenerationPreferences(
    _ preferences: AutomaticGenerationPreferences
  ) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: """
            INSERT INTO model_generation_preferences
              (singleton, is_enabled, disclosure_acknowledged)
            VALUES (1, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET
              is_enabled = excluded.is_enabled,
              disclosure_acknowledged = excluded.disclosure_acknowledged
            """,
          arguments: [
            preferences.isEnabled,
            preferences.disclosureAcknowledged,
          ]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func transcriptQualityPreferences() async throws
    -> TranscriptQualityPreferences
  {
    do {
      return try await databasePool.read { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT is_enabled
              FROM transcript_quality_preferences
              WHERE singleton = 1
              """
          )
        else {
          return TranscriptQualityPreferences()
        }
        return TranscriptQualityPreferences(isEnabled: row["is_enabled"])
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func setTranscriptQualityPreferences(
    _ preferences: TranscriptQualityPreferences
  ) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: """
            INSERT INTO transcript_quality_preferences
              (singleton, is_enabled)
            VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET
              is_enabled = excluded.is_enabled
            """,
          arguments: [preferences.isEnabled]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func unfinishedTaskCount(
    for profileID: ModelProfileID
  ) async throws -> Int {
    do {
      return try await databasePool.read { database in
        try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM model_profile_usage
            WHERE profile_id = ?
            """,
          arguments: [profileID.rawValue.uuidString]
        ) ?? 0
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func registerUnfinishedTask(
    _ task: ModelProfileTaskReference,
    profileID: ModelProfileID
  ) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: """
            INSERT INTO model_profile_usage (task_reference, profile_id)
            VALUES (?, ?)
            ON CONFLICT(task_reference) DO UPDATE SET
              profile_id = excluded.profile_id
            """,
          arguments: [
            task.rawValue.uuidString,
            profileID.rawValue.uuidString,
          ]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func finishTask(
    _ task: ModelProfileTaskReference
  ) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: """
            DELETE FROM model_profile_usage
            WHERE task_reference = ?
            """,
          arguments: [task.rawValue.uuidString]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func reconcileUnfinishedTasks(
    keeping taskReferences: Set<ModelProfileTaskReference>
  ) async throws {
    let keptReferences = Set(
      taskReferences.map { $0.rawValue.uuidString }
    )
    do {
      try await databasePool.write { database in
        let existingReferences = try String.fetchAll(
          database,
          sql: "SELECT task_reference FROM model_profile_usage"
        )
        for reference in existingReferences
        where !keptReferences.contains(reference) {
          try database.execute(
            sql: "DELETE FROM model_profile_usage WHERE task_reference = ?",
            arguments: [reference]
          )
        }
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func delete(_ id: ModelProfileID) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: "DELETE FROM model_profile_usage WHERE profile_id = ?",
          arguments: [id.rawValue.uuidString]
        )
        try database.execute(
          sql: "DELETE FROM model_profile WHERE profile_id = ?",
          arguments: [id.rawValue.uuidString]
        )
      }
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  public func close() throws {
    do {
      try databasePool.close()
    } catch {
      throw ModelProfileStoreError.unavailable
    }
  }

  private static func profile(_ row: Row) throws -> ModelProfile {
    guard
      let profileID = UUID(uuidString: row["profile_id"]),
      let baseURL = URL(string: row["base_url"]),
      let credentialReference = UUID(
        uuidString: row["credential_reference"]
      )
    else {
      throw ModelProfileStoreError.invalidData
    }
    return ModelProfile(
      id: ModelProfileID(rawValue: profileID),
      name: row["name"],
      baseURL: baseURL,
      model: row["model"],
      parameters: ModelGenerationParameters(
        temperature: row["temperature"],
        maximumOutputTokens: row["maximum_output_tokens"],
        usesStreaming: row["uses_streaming"]
      ),
      credentialReference: ModelCredentialReference(
        rawValue: credentialReference
      ),
      isUsable: row["is_usable"]
    )
  }
}
