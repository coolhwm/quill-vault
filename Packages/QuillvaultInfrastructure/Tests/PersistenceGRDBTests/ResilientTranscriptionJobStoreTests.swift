import Domain
import Foundation
import Testing

@testable import PersistenceGRDB

@Suite("Resilient transcription job store")
struct ResilientTranscriptionJobStoreTests {
  @Test("Fallback survives a primary write failure and cold start")
  func fallbackSurvivesPrimaryFailure() async throws {
    let fallbackURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
      .appending(path: "pending-transcriptions.json")
    let job = fixtureJob()
    let failingPrimary = TranscriptionJobStoreStub(failSave: true)
    let firstStore = ResilientTranscriptionJobStore(
      primary: failingPrimary,
      fallbackURL: fallbackURL
    )

    try await firstStore.savePending(job)

    let reopenedPrimary = TranscriptionJobStoreStub()
    let reopenedStore = ResilientTranscriptionJobStore(
      primary: reopenedPrimary,
      fallbackURL: fallbackURL
    )
    #expect(try await reopenedStore.pendingJobs() == [job])

    try await reopenedStore.markPublished(
      meetingID: job.meetingID,
      revision: TranscriptRevision(
        meetingID: job.meetingID,
        localeIdentifier: job.localeIdentifier,
        timeline: TranscriptTimeline(
          audioDurationSeconds: job.audioDurationSeconds,
          segments: []
        )
      )
    )
    let afterPublication = ResilientTranscriptionJobStore(
      primary: reopenedPrimary,
      fallbackURL: fallbackURL
    )
    #expect(try await afterPublication.pendingJobs().isEmpty)
  }

  private func fixtureJob() -> TranscriptionJob {
    TranscriptionJob(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "7E66FE03-7589-42E2-BF1E-955D87BE6729")!
      ),
      recordingURL: URL(fileURLWithPath: "/tmp/recording.m4a"),
      audioDurationSeconds: 42,
      localeIdentifier: "zh-CN"
    )
  }
}

private actor TranscriptionJobStoreStub: TranscriptionJobStore {
  private let failSave: Bool
  private var jobs: [TranscriptionJob] = []

  init(failSave: Bool = false) {
    self.failSave = failSave
  }

  func savePending(_ job: TranscriptionJob) throws {
    if failSave {
      throw CocoaError(.fileWriteUnknown)
    }
    jobs = [job]
  }

  func pendingJobs() -> [TranscriptionJob] {
    jobs
  }

  func markPublished(
    meetingID: MeetingID,
    revision: TranscriptRevision
  ) {
    jobs.removeAll { $0.meetingID == meetingID }
  }
}
