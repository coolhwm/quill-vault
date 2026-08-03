import Domain
import Foundation

public actor TranscriptionWorkflow: TranscriptionUseCase {
  private let engine: any SpeechTranscriptionEngine
  private let publisher: any TranscriptPublisher
  private let jobs: any TranscriptionJobStore
  private let assetAccess: (any RecordingAssetAccess)?
  private let recoverySource: (any TranscriptionRecoverySource)?
  private let diagnostics: any DiagnosticRecorder
  private let now: @Sendable () -> Date
  private var activeMeetings = Set<MeetingID>()

  public init(
    engine: any SpeechTranscriptionEngine,
    publisher: any TranscriptPublisher,
    jobs: any TranscriptionJobStore,
    assetAccess: (any RecordingAssetAccess)? = nil,
    recoverySource: (any TranscriptionRecoverySource)? = nil,
    diagnostics: any DiagnosticRecorder = NoopDiagnosticRecorder(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.engine = engine
    self.publisher = publisher
    self.jobs = jobs
    self.assetAccess = assetAccess
    self.recoverySource = recoverySource
    self.diagnostics = diagnostics
    self.now = now
  }

  public func finalize(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) async throws -> TranscriptRevision {
    let job = try makeJob(
      completion,
      localeIdentifier: localeIdentifier
    )
    try await jobs.savePending(job)
    return try await run(job)
  }

  public func enqueue(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) async throws {
    try await jobs.savePending(
      makeJob(completion, localeIdentifier: localeIdentifier)
    )
  }

  public func recoverPending() async throws -> [TranscriptionRecoveryResult] {
    if let recoverySource {
      do {
        let recoveredJobs =
          try await recoverySource
          .recoverableTranscriptionJobs(
            localeIdentifier: Locale.current.identifier
          )
        for job in recoveredJobs {
          try await jobs.savePending(job)
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Existing durable jobs remain recoverable even when the selected
        // external directory is temporarily unavailable.
      }
    }
    let pending = try await jobs.pendingJobs()

    var results: [TranscriptionRecoveryResult] = []
    for job in pending.sorted(by: {
      $0.meetingID.rawValue.uuidString < $1.meetingID.rawValue.uuidString
    }) {
      do {
        let revision = try await run(job)
        results.append(
          TranscriptionRecoveryResult(
            meetingID: job.meetingID,
            result: .success(revision)
          )
        )
      } catch is CancellationError {
        throw CancellationError()
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

  private func makeJob(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) throws -> TranscriptionJob {
    guard let recordingURL = completion.audio.fileURL else {
      throw TranscriptError.recognitionFailed
    }
    return TranscriptionJob(
      meetingID: completion.session.meetingID,
      recordingURL: recordingURL,
      audioDurationSeconds: completion.audio.durationSeconds,
      localeIdentifier: localeIdentifier
    )
  }

  private func run(_ job: TranscriptionJob) async throws -> TranscriptRevision {
    guard activeMeetings.insert(job.meetingID).inserted else {
      throw TranscriptError.recognitionFailed
    }
    defer {
      activeMeetings.remove(job.meetingID)
    }
    let startedAt = now()
    await diagnostics.record(
      DiagnosticEvent(
        timestamp: startedAt,
        kind: .transcriptionStarted,
        correlation: DiagnosticCorrelation(meetingID: job.meetingID.rawValue)
      )
    )

    do {
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
      let finishedAt = now()
      await diagnostics.record(
        DiagnosticEvent(
          timestamp: finishedAt,
          kind: .transcriptionFinished,
          correlation: DiagnosticCorrelation(meetingID: job.meetingID.rawValue),
          durationMilliseconds: max(
            0,
            Int(finishedAt.timeIntervalSince(startedAt) * 1_000)
          )
        )
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
