import Domain
import Foundation
import GRDB

public actor GRDBGenerationJobStore: GenerationJobStore {
  private let databasePool: DatabasePool

  private init(databasePool: DatabasePool) {
    self.databasePool = databasePool
  }

  public static func open(
    at databaseURL: URL
  ) throws -> GRDBGenerationJobStore {
    do {
      try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      var configuration = Configuration()
      configuration.foreignKeysEnabled = true
      configuration.busyMode = .timeout(5)
      let pool = try DatabasePool(path: databaseURL.path(), configuration: configuration)
      var migrator = DatabaseMigrator()
      migrator.registerMigration("v1_create_generation_jobs") { database in
        try database.create(table: "generation_job") { table in
          table.column("job_id", .text).primaryKey()
          table.column("meeting_id", .text).notNull()
          table.column("transcript_revision_id", .text).notNull()
          table.column("transcript_fingerprint", .text).notNull()
          table.column("profile_id", .text).notNull()
          table.column("profile_base_url", .text).notNull()
          table.column("profile_model", .text).notNull()
          table.column("temperature", .double).notNull()
          table.column("maximum_output_tokens", .integer).notNull()
          table.column("uses_streaming", .boolean).notNull()
          table.column("credential_reference", .text).notNull()
          table.column("prompt_version", .text).notNull()
          table.column("schema_version", .text).notNull()
          table.column("chunk_plan_version", .text).notNull()
          table.column("generation_number", .integer).notNull()
          table.column("total_steps", .integer).notNull()
          table.column("completed_step_count", .integer).notNull()
          table.column("progress", .integer).notNull()
          table.column("stage", .text).notNull()
          table.column("state", .text).notNull()
          table.column("pause_reason", .text)
          table.column("created_at", .double).notNull()
          table.column("updated_at", .double).notNull()
          table.column("completed_at", .double)
        }
        try database.execute(
          sql: """
            CREATE UNIQUE INDEX generation_job_active_meeting
            ON generation_job (meeting_id)
            WHERE state <> 'completed'
            """
        )
        try database.create(table: "generation_step") { table in
          table.column("step_id", .text).primaryKey()
          table.column("job_id", .text).notNull()
            .references("generation_job", onDelete: .cascade)
          table.column("kind", .text).notNull()
          table.column("step_index", .integer).notNull()
          table.column("input_fingerprint", .text).notNull()
          table.column("output_text", .text).notNull()
          table.column("progress", .integer).notNull()
          table.column("completed_at", .double).notNull()
          table.uniqueKey(["job_id", "kind", "step_index"])
        }
      }
      migrator.registerMigration("v2_generation_pipeline") { database in
        try database.alter(table: "generation_job") { table in
          table.add(column: "chunk_count", .integer)
            .notNull()
            .defaults(to: 1)
          table.add(column: "completed_chunk_count", .integer)
            .notNull()
            .defaults(to: 0)
          table.add(column: "retry_attempt", .integer)
            .notNull()
            .defaults(to: 0)
          table.add(column: "next_retry_at", .double)
        }
      }
      try migrator.migrate(pool)
      return GRDBGenerationJobStore(databasePool: pool)
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func create(_ job: GenerationJob) async throws {
    do {
      try await databasePool.write { database in
        let activeCount =
          try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM generation_job WHERE state <> 'completed'"
          ) ?? 0
        guard activeCount < 20 else {
          throw GenerationJobStoreError.queueFull
        }
        try Self.insert(job, in: database)
      }
    } catch let error as GenerationJobStoreError {
      throw error
    } catch let error as DatabaseError
      where error.resultCode == .SQLITE_CONSTRAINT
    {
      throw GenerationJobStoreError.conflict
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func load(_ id: UUID) async throws -> GenerationSnapshot? {
    do {
      return try await databasePool.read { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM generation_job WHERE job_id = ?",
            arguments: [id.uuidString]
          )
        else {
          return nil
        }
        return GenerationSnapshot(
          job: try Self.decodeJob(row),
          completedSteps: try Self.decodeSteps(
            jobID: id,
            in: database
          )
        )
      }
    } catch let error as GenerationJobStoreError {
      throw error
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func activeJob(
    for meetingID: MeetingID
  ) async throws -> GenerationSnapshot? {
    do {
      return try await databasePool.read { database in
        guard
          let row = try Row.fetchOne(
            database,
            sql: """
              SELECT * FROM generation_job
              WHERE meeting_id = ? AND state <> 'completed'
              ORDER BY generation_number DESC
              LIMIT 1
              """,
            arguments: [meetingID.rawValue.uuidString]
          )
        else {
          return nil
        }
        let job = try Self.decodeJob(row)
        return GenerationSnapshot(
          job: job,
          completedSteps: try Self.decodeSteps(jobID: job.id, in: database)
        )
      }
    } catch let error as GenerationJobStoreError {
      throw error
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func resumableJobs() async throws -> [GenerationSnapshot] {
    do {
      return try await databasePool.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT * FROM generation_job
            WHERE state <> 'completed'
            ORDER BY created_at ASC, job_id ASC
            """
        ).map { row in
          let job = try Self.decodeJob(row)
          return GenerationSnapshot(
            job: job,
            completedSteps: try Self.decodeSteps(jobID: job.id, in: database)
          )
        }
      }
    } catch let error as GenerationJobStoreError {
      throw error
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func saveCheckpoint(
    _ job: GenerationJob,
    step: GenerationStep?
  ) async throws {
    do {
      try await databasePool.write { database in
        if let previous = try Row.fetchOne(
          database,
          sql: "SELECT progress FROM generation_job WHERE job_id = ?",
          arguments: [job.id.uuidString]
        ),
          let previousProgress: Int = previous["progress"],
          job.progress < previousProgress
        {
          throw GenerationJobStoreError.invalidData
        }
        try Self.insertOrUpdate(job, in: database)
        if let step {
          try database.execute(
            sql: """
              INSERT INTO generation_step
                (
                  step_id, job_id, kind, step_index, input_fingerprint,
                  output_text, progress, completed_at
                )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(job_id, kind, step_index) DO UPDATE SET
                step_id = excluded.step_id,
                input_fingerprint = excluded.input_fingerprint,
                output_text = excluded.output_text,
                progress = excluded.progress,
                completed_at = excluded.completed_at
              """,
            arguments: [
              step.id,
              step.jobID.uuidString,
              step.kind.rawValue,
              step.index,
              step.inputFingerprint,
              step.output,
              step.progress,
              step.completedAt.timeIntervalSince1970,
            ]
          )
        }
      }
    } catch let error as GenerationJobStoreError {
      throw error
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func delete(_ id: UUID) async throws {
    do {
      try await databasePool.write { database in
        try database.execute(
          sql: "DELETE FROM generation_job WHERE job_id = ?",
          arguments: [id.uuidString]
        )
      }
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  public func close() throws {
    do {
      try databasePool.close()
    } catch {
      throw GenerationJobStoreError.unavailable
    }
  }

  private static func insert(
    _ job: GenerationJob,
    in database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO generation_job
          (
            job_id, meeting_id, transcript_revision_id,
            transcript_fingerprint, profile_id, profile_base_url,
            profile_model, temperature, maximum_output_tokens,
            uses_streaming, credential_reference, prompt_version,
            schema_version, chunk_plan_version, generation_number,
            chunk_count, total_steps, completed_step_count,
            completed_chunk_count, progress, retry_attempt, next_retry_at,
            stage, state, pause_reason, created_at, updated_at, completed_at
          )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: Self.arguments(for: job)
    )
  }

  private static func insertOrUpdate(
    _ job: GenerationJob,
    in database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO generation_job
          (
            job_id, meeting_id, transcript_revision_id,
            transcript_fingerprint, profile_id, profile_base_url,
            profile_model, temperature, maximum_output_tokens,
            uses_streaming, credential_reference, prompt_version,
            schema_version, chunk_plan_version, generation_number,
            chunk_count, total_steps, completed_step_count,
            completed_chunk_count, progress, retry_attempt, next_retry_at,
            stage, state, pause_reason, created_at, updated_at, completed_at
          )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(job_id) DO UPDATE SET
          chunk_count = excluded.chunk_count,
          total_steps = excluded.total_steps,
          completed_step_count = excluded.completed_step_count,
          completed_chunk_count = excluded.completed_chunk_count,
          progress = excluded.progress,
          retry_attempt = excluded.retry_attempt,
          next_retry_at = excluded.next_retry_at,
          stage = excluded.stage,
          state = excluded.state,
          pause_reason = excluded.pause_reason,
          updated_at = excluded.updated_at,
          completed_at = excluded.completed_at
        """,
      arguments: Self.arguments(for: job)
    )
  }

  private static func arguments(for job: GenerationJob) -> StatementArguments {
    [
      job.id.uuidString,
      job.meetingID.rawValue.uuidString,
      job.transcriptRevisionID,
      job.transcriptFingerprint,
      job.modelProfile.profileID.rawValue.uuidString,
      job.modelProfile.baseURL.absoluteString,
      job.modelProfile.model,
      job.modelProfile.parameters.temperature,
      job.modelProfile.parameters.maximumOutputTokens,
      job.modelProfile.parameters.usesStreaming,
      job.modelProfile.credentialReference.rawValue.uuidString,
      job.promptVersion,
      job.schemaVersion,
      job.chunkPlanVersion,
      job.generationNumber,
      job.chunkCount,
      job.totalSteps,
      job.completedStepCount,
      job.completedChunkCount,
      job.progress,
      job.retryAttempt,
      job.nextRetryAt?.timeIntervalSince1970,
      job.stage.rawValue,
      job.state.rawValue,
      job.pauseReason?.rawValue,
      job.createdAt.timeIntervalSince1970,
      job.updatedAt.timeIntervalSince1970,
      job.completedAt?.timeIntervalSince1970,
    ]
  }

  private static func decodeJob(_ row: Row) throws -> GenerationJob {
    guard
      let id = UUID(uuidString: row["job_id"]),
      let meetingID = UUID(uuidString: row["meeting_id"]),
      let profileID = UUID(uuidString: row["profile_id"]),
      let baseURL = URL(string: row["profile_base_url"]),
      let credentialReference = UUID(
        uuidString: row["credential_reference"]
      ),
      let stage = GenerationStage(rawValue: row["stage"]),
      let state = GenerationJobState(rawValue: row["state"]),
      let pauseRaw: String? = row["pause_reason"]
    else {
      throw GenerationJobStoreError.invalidData
    }
    let createdAt = Date(timeIntervalSince1970: row["created_at"])
    let updatedAt = Date(timeIntervalSince1970: row["updated_at"])
    let completedAt: Date? = (row["completed_at"] as Double?)
      .map(Date.init(timeIntervalSince1970:))
    return GenerationJob(
      id: id,
      meetingID: MeetingID(rawValue: meetingID),
      transcriptRevisionID: row["transcript_revision_id"],
      transcriptFingerprint: row["transcript_fingerprint"],
      modelProfile: ModelProfileSnapshot(
        profileID: ModelProfileID(rawValue: profileID),
        baseURL: baseURL,
        model: row["profile_model"],
        parameters: ModelGenerationParameters(
          temperature: row["temperature"],
          maximumOutputTokens: row["maximum_output_tokens"],
          usesStreaming: row["uses_streaming"]
        ),
        credentialReference: ModelCredentialReference(
          rawValue: credentialReference
        )
      ),
      promptVersion: row["prompt_version"],
      schemaVersion: row["schema_version"],
      chunkPlanVersion: row["chunk_plan_version"],
      generationNumber: row["generation_number"],
      chunkCount: row["chunk_count"],
      totalSteps: row["total_steps"],
      createdAt: createdAt,
      updatedAt: updatedAt,
      completedAt: completedAt,
      state: state,
      stage: stage,
      progress: row["progress"],
      completedStepCount: row["completed_step_count"],
      completedChunkCount: row["completed_chunk_count"],
      retryAttempt: row["retry_attempt"],
      nextRetryAt: (row["next_retry_at"] as Double?)
        .map(Date.init(timeIntervalSince1970:)),
      pauseReason: pauseRaw.flatMap(GenerationPauseReason.init(rawValue:))
    )
  }

  private static func decodeSteps(
    jobID: UUID,
    in database: Database
  ) throws -> [GenerationStep] {
    try Row.fetchAll(
      database,
      sql: """
        SELECT * FROM generation_step
        WHERE job_id = ?
        ORDER BY kind ASC, step_index ASC
        """,
      arguments: [jobID.uuidString]
    ).map { row in
      guard let kind = GenerationStepKind(rawValue: row["kind"]) else {
        throw GenerationJobStoreError.invalidData
      }
      let completedAt = Date(timeIntervalSince1970: row["completed_at"])
      return GenerationStep(
        id: row["step_id"],
        jobID: jobID,
        kind: kind,
        index: row["step_index"],
        inputFingerprint: row["input_fingerprint"],
        output: row["output_text"],
        progress: row["progress"],
        completedAt: completedAt
      )
    }
  }
}
