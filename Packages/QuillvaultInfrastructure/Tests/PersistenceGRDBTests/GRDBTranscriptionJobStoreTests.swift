import Domain
import Foundation
import GRDB
import Testing

@testable import PersistenceGRDB

@Suite("GRDB transcription job store")
struct GRDBTranscriptionJobStoreTests {
  @Test("Pending finalization survives a cold start")
  func pendingSurvivesReopen() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let job = fixture.job()
    let first = try GRDBTranscriptionJobStore.open(at: fixture.databaseURL)
    try await first.savePending(job)

    let reopened = try GRDBTranscriptionJobStore.open(at: fixture.databaseURL)

    #expect(try await reopened.pendingJobs() == [job])
  }

  @Test("Publishing atomically removes pending work and stores revision identity")
  func publicationCompletesJob() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let job = fixture.job()
    let store = try GRDBTranscriptionJobStore.open(at: fixture.databaseURL)
    try await store.savePending(job)
    let revision = fixture.revision()

    try await store.markPublished(
      meetingID: job.meetingID,
      revision: revision
    )

    #expect(try await store.pendingJobs().isEmpty)
    let database = try DatabasePool(path: fixture.databaseURL.path)
    let row = try database.read { database in
      try Row.fetchOne(
        database,
        sql: """
          SELECT revision_id, content_fingerprint
          FROM published_transcript
          WHERE meeting_id = ?
          """,
        arguments: [job.meetingID.rawValue.uuidString]
      )
    }
    #expect(row?["revision_id"] as String? == revision.id)
    #expect(row?["content_fingerprint"] as String? == revision.contentFingerprint)
  }

  @Test("Saving the same meeting updates its recoverable location")
  func pendingUpsert() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try GRDBTranscriptionJobStore.open(at: fixture.databaseURL)
    let first = fixture.job()
    try await store.savePending(first)
    let second = TranscriptionJob(
      meetingID: first.meetingID,
      recordingURL: first.recordingURL.deletingLastPathComponent()
        .appending(path: "moved-recording.m4a"),
      audioDurationSeconds: 42,
      localeIdentifier: "en-US"
    )

    try await store.savePending(second)

    #expect(try await store.pendingJobs() == [second])
  }
}

private struct Fixture {
  let rootURL: URL
  let databaseURL: URL
  let meetingID = MeetingID(
    rawValue: UUID(uuidString: "1DF40EA0-E9B7-44F2-B2CA-B0112CC7DB56")!
  )

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "transcription-jobs-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    databaseURL = rootURL.appending(path: "jobs.sqlite")
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
  }

  func job() -> TranscriptionJob {
    TranscriptionJob(
      meetingID: meetingID,
      recordingURL: rootURL.appending(path: "recording.m4a"),
      audioDurationSeconds: 10,
      localeIdentifier: "zh-CN"
    )
  }

  func revision() -> TranscriptRevision {
    TranscriptRevision(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(
        audioDurationSeconds: 10,
        segments: []
      )
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
