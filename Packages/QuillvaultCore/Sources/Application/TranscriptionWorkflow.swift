import Domain
import Foundation

public actor TranscriptionWorkflow: TranscriptionUseCase {
  private let engine: any SpeechTranscriptionEngine
  private let publisher: any TranscriptPublisher
  private let jobs: any TranscriptionJobStore
  private let assetAccess: (any RecordingAssetAccess)?
  private var activeMeetings = Set<MeetingID>()

  public init(
    engine: any SpeechTranscriptionEngine,
    publisher: any TranscriptPublisher,
    jobs: any TranscriptionJobStore,
    assetAccess: (any RecordingAssetAccess)? = nil
  ) {
    self.engine = engine
    self.publisher = publisher
    self.jobs = jobs
    self.assetAccess = assetAccess
  }

  public func finalize(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) async throws -> TranscriptRevision {
    guard let recordingURL = completion.audio.fileURL else {
      throw TranscriptError.recognitionFailed
    }
    let job = TranscriptionJob(
      meetingID: completion.session.meetingID,
      recordingURL: recordingURL,
      audioDurationSeconds: completion.audio.durationSeconds,
      localeIdentifier: localeIdentifier
    )
    return try await run(job, persistPending: true)
  }

  public func recoverPending() async -> [TranscriptionRecoveryResult] {
    let pending: [TranscriptionJob]
    do {
      pending = try await jobs.pendingJobs()
    } catch {
      return []
    }

    var results: [TranscriptionRecoveryResult] = []
    for job in pending.sorted(by: {
      $0.meetingID.rawValue.uuidString < $1.meetingID.rawValue.uuidString
    }) {
      do {
        let revision = try await run(job, persistPending: false)
        results.append(
          TranscriptionRecoveryResult(
            meetingID: job.meetingID,
            result: .success(revision)
          )
        )
      } catch let error as TranscriptError {
        results.append(
          TranscriptionRecoveryResult(
            meetingID: job.meetingID,
            result: .failure(error)
          )
        )
      } catch {
        results.append(
          TranscriptionRecoveryResult(
            meetingID: job.meetingID,
            result: .failure(.recognitionFailed)
          )
        )
      }
    }
    return results
  }

  private func run(
    _ job: TranscriptionJob,
    persistPending: Bool
  ) async throws -> TranscriptRevision {
    guard activeMeetings.insert(job.meetingID).inserted else {
      throw TranscriptError.recognitionFailed
    }
    defer {
      activeMeetings.remove(job.meetingID)
    }

    do {
      if persistPending {
        try await jobs.savePending(job)
      }
      let accessibleRecordingURL: URL
      do {
        accessibleRecordingURL =
          try await assetAccess?.beginTranscriptionAccess(
            meetingID: job.meetingID,
            recordingURL: job.recordingURL
          ) ?? job.recordingURL
      } catch {
        throw TranscriptError.recordingUnavailable
      }
      let stream = try await engine.fileResults(
        at: accessibleRecordingURL,
        localeIdentifier: job.localeIdentifier
      )
      var finalSegments: [TranscriptSegmentCandidate] = []
      for try await event in stream {
        try Task.checkCancellation()
        guard event.stability == .final else {
          continue
        }
        try await publisher.appendFinal(
          event.segment,
          meetingID: job.meetingID,
          recordingURL: accessibleRecordingURL
        )
        finalSegments.append(event.segment)
      }
      try Task.checkCancellation()

      let timeline = try TranscriptTimeline.normalizing(
        finalSegments,
        audioDurationSeconds: job.audioDurationSeconds
      )
      let candidate = TranscriptRevision(
        meetingID: job.meetingID,
        localeIdentifier: job.localeIdentifier,
        timeline: timeline
      )
      let published = try await publisher.publish(
        candidate,
        recordingURL: accessibleRecordingURL
      )
      guard
        published.id == candidate.id,
        published.contentFingerprint == candidate.contentFingerprint
      else {
        throw TranscriptError.publicationFailed
      }
      try await jobs.markPublished(
        meetingID: job.meetingID,
        revision: published
      )
      await assetAccess?.endTranscriptionAccess(meetingID: job.meetingID)
      return published
    } catch is CancellationError {
      await assetAccess?.endTranscriptionAccess(meetingID: job.meetingID)
      throw CancellationError()
    } catch let error as TranscriptError {
      await assetAccess?.endTranscriptionAccess(meetingID: job.meetingID)
      throw error
    } catch {
      await assetAccess?.endTranscriptionAccess(meetingID: job.meetingID)
      throw TranscriptError.recognitionFailed
    }
  }
}
