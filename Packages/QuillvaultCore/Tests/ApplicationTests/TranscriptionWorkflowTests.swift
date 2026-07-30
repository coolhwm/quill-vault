import Application
import Domain
import Foundation
import Testing

@Suite("Transcription workflow")
struct TranscriptionWorkflowTests {
  private let meetingID = MeetingID(
    rawValue: UUID(uuidString: "AD16F7B4-A357-4E29-8C82-BE391E1CE9F4")!
  )
  private let recordingURL = URL(fileURLWithPath: "/tmp/meeting/recording.m4a")

  @Test("Only final results are logged and published")
  func publishesFinalResultsOnly() async throws {
    let engine = SpeechEngineStub(
      events: [
        event(0, 1, "临时", .volatile),
        event(0, 1, "最终第一句", .final),
        event(1, 2, "最终第二句", .final),
      ]
    )
    let publisher = TranscriptPublisherStub()
    let jobs = TranscriptionJobStoreStub()
    let workflow = TranscriptionWorkflow(
      engine: engine,
      publisher: publisher,
      jobs: jobs
    )

    let revision = try await workflow.finalize(
      completion(),
      localeIdentifier: "zh-CN"
    )

    #expect(revision.timeline.segments.map(\.text) == ["最终第一句", "最终第二句"])
    #expect(await publisher.appended.map(\.text) == ["最终第一句", "最终第二句"])
    #expect(await jobs.publishedRevision == revision)
  }

  @Test("Zero speech and one result are both valid publishable transcripts")
  func zeroAndOneResult() async throws {
    for events in [
      [SpeechRecognitionEvent](),
      [event(0, 1, "一句", .final)],
    ] {
      let workflow = TranscriptionWorkflow(
        engine: SpeechEngineStub(events: events),
        publisher: TranscriptPublisherStub(),
        jobs: TranscriptionJobStoreStub()
      )

      let revision = try await workflow.finalize(
        completion(),
        localeIdentifier: "zh-CN"
      )
      #expect(revision.timeline.segments.count == events.count)
    }
  }

  @Test("A failed recognizer preserves the pending recovery job")
  func recognitionFailureRemainsPending() async {
    let jobs = TranscriptionJobStoreStub()
    let workflow = TranscriptionWorkflow(
      engine: SpeechEngineStub(streamError: TestFailure()),
      publisher: TranscriptPublisherStub(),
      jobs: jobs
    )

    await #expect(throws: TranscriptError.recognitionFailed) {
      _ = try await workflow.finalize(
        completion(),
        localeIdentifier: "zh-CN"
      )
    }
    #expect(await jobs.pending.count == 1)
    #expect(await jobs.publishedRevision == nil)
  }

  @Test("A failed atomic publication never marks the transcript ready")
  func publicationFailureRemainsPending() async {
    let jobs = TranscriptionJobStoreStub()
    let workflow = TranscriptionWorkflow(
      engine: SpeechEngineStub(events: [event(0, 1, "内容", .final)]),
      publisher: TranscriptPublisherStub(publishError: TranscriptError.publicationFailed),
      jobs: jobs
    )

    await #expect(throws: TranscriptError.publicationFailed) {
      _ = try await workflow.finalize(
        completion(),
        localeIdentifier: "zh-CN"
      )
    }
    #expect(await jobs.pending.count == 1)
    #expect(await jobs.publishedRevision == nil)
  }

  @Test("Read-back identity mismatch never marks the transcript ready")
  func readbackMismatch() async {
    let jobs = TranscriptionJobStoreStub()
    let publisher = TranscriptPublisherStub(mutatesReadback: true)
    let workflow = TranscriptionWorkflow(
      engine: SpeechEngineStub(events: [event(0, 1, "内容", .final)]),
      publisher: publisher,
      jobs: jobs
    )

    await #expect(throws: TranscriptError.publicationFailed) {
      _ = try await workflow.finalize(
        completion(),
        localeIdentifier: "zh-CN"
      )
    }
    #expect(await jobs.publishedRevision == nil)
  }

  @Test("Cold-start recovery retries every pending finalization")
  func recoversPendingJobs() async {
    let secondID = MeetingID(
      rawValue: UUID(uuidString: "AA5C5D2B-CE39-4E12-98D3-658162634EB5")!
    )
    let jobs = TranscriptionJobStoreStub(
      pending: [
        job(meetingID: meetingID),
        job(meetingID: secondID),
      ]
    )
    let workflow = TranscriptionWorkflow(
      engine: SpeechEngineStub(events: [event(0, 1, "已恢复", .final)]),
      publisher: TranscriptPublisherStub(),
      jobs: jobs
    )

    let results = await workflow.recoverPending()

    #expect(results.count == 2)
    #expect(
      results.allSatisfy {
        if case .success = $0.result {
          return true
        }
        return false
      })
    #expect(await jobs.pending.isEmpty)
  }

  @Test("Cancellation leaves the durable job recoverable")
  func cancellationPreservesPendingJob() async {
    let jobs = TranscriptionJobStoreStub()
    let workflow = TranscriptionWorkflow(
      engine: SpeechEngineStub(delay: .seconds(5)),
      publisher: TranscriptPublisherStub(),
      jobs: jobs
    )
    let task = Task {
      try await workflow.finalize(
        completion(),
        localeIdentifier: "zh-CN"
      )
    }

    while await jobs.pending.isEmpty {
      await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(await jobs.pending.count == 1)
  }

  @Test("Scoped recording access is released after publication failure")
  func releasesScopedAccessOnFailure() async {
    let access = RecordingAssetAccessStub()
    let workflow = TranscriptionWorkflow(
      engine: SpeechEngineStub(events: [event(0, 1, "内容", .final)]),
      publisher: TranscriptPublisherStub(
        publishError: TranscriptError.publicationFailed
      ),
      jobs: TranscriptionJobStoreStub(),
      assetAccess: access
    )

    await #expect(throws: TranscriptError.publicationFailed) {
      _ = try await workflow.finalize(
        completion(),
        localeIdentifier: "zh-CN"
      )
    }
    #expect(await access.beginCount == 1)
    #expect(await access.endCount == 1)
  }

  private func completion() -> RecordingCompletion {
    RecordingCompletion(
      session: RecordingSession(
        meetingID: meetingID,
        startedAt: Date(timeIntervalSince1970: 1_722_470_400)
      ),
      audio: RecordedAudio(
        durationSeconds: 10,
        packetCount: 100,
        byteCount: 1_024,
        fileURL: recordingURL
      )
    )
  }

  private func job(meetingID: MeetingID) -> TranscriptionJob {
    TranscriptionJob(
      meetingID: meetingID,
      recordingURL: recordingURL,
      audioDurationSeconds: 10,
      localeIdentifier: "zh-CN"
    )
  }

  private func event(
    _ start: Double,
    _ end: Double,
    _ text: String,
    _ stability: SpeechRecognitionStability
  ) -> SpeechRecognitionEvent {
    SpeechRecognitionEvent(
      segment: TranscriptSegmentCandidate(
        startSeconds: start,
        endSeconds: end,
        text: text
      ),
      stability: stability
    )
  }
}

private struct TestFailure: Error {}

private struct SpeechEngineStub: SpeechTranscriptionEngine {
  let events: [SpeechRecognitionEvent]
  let streamError: (any Error)?
  let delay: Duration?

  init(
    events: [SpeechRecognitionEvent] = [],
    streamError: (any Error)? = nil,
    delay: Duration? = nil
  ) {
    self.events = events
    self.streamError = streamError
    self.delay = delay
  }

  func liveResults(
    frames: AsyncStream<AudioFrame>,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    stream()
  }

  func fileResults(
    at recordingURL: URL,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    stream()
  }

  private func stream() -> SpeechRecognitionStream {
    AsyncThrowingStream { continuation in
      let events = events
      let streamError = streamError
      let delay = delay
      let task = Task {
        do {
          if let delay {
            try await Task.sleep(for: delay)
          }
          for event in events {
            try Task.checkCancellation()
            continuation.yield(event)
          }
          if let streamError {
            continuation.finish(throwing: streamError)
          } else {
            continuation.finish()
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private actor TranscriptPublisherStub: TranscriptPublisher {
  private let publishError: TranscriptError?
  private let mutatesReadback: Bool
  private(set) var appended: [TranscriptSegmentCandidate] = []

  init(
    publishError: TranscriptError? = nil,
    mutatesReadback: Bool = false
  ) {
    self.publishError = publishError
    self.mutatesReadback = mutatesReadback
  }

  func appendFinal(
    _ segment: TranscriptSegmentCandidate,
    meetingID: MeetingID,
    recordingURL: URL
  ) {
    appended.append(segment)
  }

  func publish(
    _ revision: TranscriptRevision,
    recordingURL: URL
  ) throws -> TranscriptRevision {
    if let publishError {
      throw publishError
    }
    guard mutatesReadback else {
      return revision
    }
    return TranscriptRevision(
      meetingID: revision.meetingID,
      localeIdentifier: revision.localeIdentifier,
      timeline: TranscriptTimeline(
        audioDurationSeconds: revision.timeline.audioDurationSeconds,
        segments: []
      )
    )
  }
}

private actor TranscriptionJobStoreStub: TranscriptionJobStore {
  private(set) var pending: [TranscriptionJob]
  private(set) var publishedRevision: TranscriptRevision?

  init(pending: [TranscriptionJob] = []) {
    self.pending = pending
  }

  func savePending(_ job: TranscriptionJob) {
    pending.removeAll { $0.meetingID == job.meetingID }
    pending.append(job)
  }

  func pendingJobs() -> [TranscriptionJob] {
    pending
  }

  func markPublished(
    meetingID: MeetingID,
    revision: TranscriptRevision
  ) {
    publishedRevision = revision
    pending.removeAll { $0.meetingID == meetingID }
  }
}

private actor RecordingAssetAccessStub: RecordingAssetAccess {
  private(set) var beginCount = 0
  private(set) var endCount = 0

  func beginTranscriptionAccess(
    meetingID: MeetingID,
    recordingURL: URL
  ) -> URL {
    beginCount += 1
    return recordingURL
  }

  func endTranscriptionAccess(meetingID: MeetingID) {
    endCount += 1
  }
}
