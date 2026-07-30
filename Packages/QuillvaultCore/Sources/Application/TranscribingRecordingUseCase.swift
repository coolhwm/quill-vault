import Domain
import Foundation

public actor TranscribingRecordingUseCase: RecordingUseCase {
  private let recording: any RecordingUseCase
  private let capture: any AudioCapture
  private let speech: any SpeechTranscriptionEngine
  private let transcription: any TranscriptionUseCase
  private let localeIdentifier: String
  private let maxLiveTranscriptSegments: Int

  private var pendingCompletion: RecordingCompletion?
  private var liveTasks: [MeetingID: Task<Void, Never>] = [:]
  private var liveSnapshots: [MeetingID: LiveTranscriptSnapshot] = [:]
  private var observers: [MeetingID: [UUID: AsyncStream<LiveTranscriptSnapshot>.Continuation]] = [:]
  private var recoveryTask: Task<[TranscriptionRecoveryResult], Error>?
  private var successfulRecoveryResults: [MeetingID: TranscriptionRecoveryResult] = [:]
  private var didStartRecovery = false
  private var activeMeetingID: MeetingID?
  private var catchUpMeetingIDs = Set<MeetingID>()

  public init(
    recording: any RecordingUseCase,
    capture: any AudioCapture,
    speech: any SpeechTranscriptionEngine,
    transcription: any TranscriptionUseCase,
    localeIdentifier: String,
    maxLiveTranscriptSegments: Int = 500
  ) {
    precondition(maxLiveTranscriptSegments > 0)
    self.recording = recording
    self.capture = capture
    self.speech = speech
    self.transcription = transcription
    self.localeIdentifier = localeIdentifier
    self.maxLiveTranscriptSegments = maxLiveTranscriptSegments
  }

  public func restore() async throws -> RecordingSnapshot? {
    let snapshot = try await recording.restore()
    startRecoveryIfNeeded()
    if let snapshot, snapshot.activity == .recording {
      activeMeetingID = snapshot.session.meetingID
      startLiveTranscription(for: snapshot.session.meetingID)
    }
    return snapshot
  }

  public func acknowledgeRecordingNotice() async throws {
    try await recording.acknowledgeRecordingNotice()
  }

  public func start() async throws -> RecordingSnapshot {
    startRecoveryIfNeeded()
    let snapshot = try await recording.start()
    activeMeetingID = snapshot.session.meetingID
    startLiveTranscription(for: snapshot.session.meetingID)
    return snapshot
  }

  public func liveTranscript(
    meetingID: MeetingID
  ) async -> AsyncStream<LiveTranscriptSnapshot> {
    let pair = AsyncStream<LiveTranscriptSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let observerID = UUID()
    observers[meetingID, default: [:]][observerID] = pair.continuation
    if let snapshot = liveSnapshots[meetingID] {
      pair.continuation.yield(snapshot)
    }
    pair.continuation.onTermination = { [weak self] _ in
      Task {
        await self?.removeObserver(
          meetingID: meetingID,
          observerID: observerID
        )
      }
    }
    return pair.stream
  }

  public func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent> {
    await recording.captureEvents(meetingID: meetingID)
  }

  public func catchUpLiveTranscript() async {
    guard
      let meetingID = activeMeetingID,
      catchUpMeetingIDs.insert(meetingID).inserted
    else {
      return
    }
    defer {
      catchUpMeetingIDs.remove(meetingID)
    }

    let audioSegments = await capture.activeRecordingAudioSegments(
      meetingID: meetingID
    )
    guard !audioSegments.isEmpty else {
      return
    }

    var caughtUp: [TranscriptSegmentCandidate] = []
    do {
      for audioSegment in audioSegments {
        let results = try await speech.fileResults(
          at: audioSegment.fileURL,
          localeIdentifier: localeIdentifier
        )
        for try await event in results
        where event.stability == .final {
          appendBounded(
            TranscriptSegmentCandidate(
              startSeconds:
                event.segment.startSeconds
                + audioSegment.timelineOffsetSeconds,
              endSeconds:
                event.segment.endSeconds
                + audioSegment.timelineOffsetSeconds,
              text: event.segment.text
            ),
            to: &caughtUp
          )
        }
      }
    } catch {
      return
    }
    guard !caughtUp.isEmpty else {
      return
    }

    let current = liveSnapshots[meetingID] ?? LiveTranscriptSnapshot()
    let candidates = current.finalSegments + caughtUp
    let duration =
      candidates.max(by: { $0.endSeconds < $1.endSeconds })?.endSeconds
      ?? current.volatileSegment?.endSeconds
      ?? 0
    guard
      let timeline = try? TranscriptTimeline.normalizing(
        candidates,
        audioDurationSeconds: max(duration, 0.001)
      )
    else {
      return
    }
    let snapshot = LiveTranscriptSnapshot(
      finalSegments: Array(
        timeline.segments.suffix(maxLiveTranscriptSegments)
      ).map {
        TranscriptSegmentCandidate(
          startSeconds: $0.startSeconds,
          endSeconds: $0.endSeconds,
          text: $0.text
        )
      },
      volatileSegment: current.volatileSegment
    )
    liveSnapshots[meetingID] = snapshot
    for observer in observers[meetingID]?.values ?? [:].values {
      observer.yield(snapshot)
    }
  }

  public func stop() async throws -> RecordingCompletion {
    let completion: RecordingCompletion
    if let pendingCompletion {
      completion = pendingCompletion
    } else {
      completion = try await recording.stop()
      pendingCompletion = completion
    }

    stopLiveTranscription(meetingID: completion.session.meetingID)
    activeMeetingID = nil
    do {
      try await enqueueCompletion(completion)
    } catch is CancellationError {
      finishObservers(meetingID: completion.session.meetingID)
      throw CancellationError()
    }
    finishObservers(meetingID: completion.session.meetingID)
    return completion
  }

  public func finishInterrupted() async throws -> RecordingCompletion {
    let completion = try await recording.finishInterrupted()
    try await enqueueCompletion(completion)
    return completion
  }

  public func resumeInterrupted() async throws -> RecordingSnapshot {
    let snapshot = try await recording.resumeInterrupted()
    activeMeetingID = snapshot.session.meetingID
    startLiveTranscription(for: snapshot.session.meetingID)
    return snapshot
  }

  public func recoverPendingTranscriptions() async throws
    -> [TranscriptionRecoveryResult]
  {
    if let pendingCompletion {
      do {
        try await transcription.enqueue(
          pendingCompletion,
          localeIdentifier: localeIdentifier
        )
        self.pendingCompletion = nil
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as TranscriptError {
        return [
          TranscriptionRecoveryResult(
            meetingID: pendingCompletion.session.meetingID,
            result: .failure(error)
          )
        ]
      } catch {
        return [
          TranscriptionRecoveryResult(
            meetingID: pendingCompletion.session.meetingID,
            result: .failure(.publicationFailed)
          )
        ]
      }
    }

    let results = try await recoverDurableJobs()
    if results.isEmpty {
      let cached = Array(successfulRecoveryResults.values)
      successfulRecoveryResults.removeAll()
      return cached
    }
    return results
  }

  private func startRecoveryIfNeeded() {
    guard !didStartRecovery else {
      return
    }
    didStartRecovery = true
    startRecovery()
  }

  private func startRecovery() {
    Task { [weak self] in
      _ = try? await self?.recoverDurableJobs()
    }
  }

  private func enqueueCompletion(
    _ completion: RecordingCompletion
  ) async throws {
    pendingCompletion = completion
    do {
      try await transcription.enqueue(
        completion,
        localeIdentifier: localeIdentifier
      )
      pendingCompletion = nil
      startRecovery()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // The validated recording remains durable and can enqueue on retry.
    }
  }

  private func recoverDurableJobs() async throws -> [TranscriptionRecoveryResult] {
    if let recoveryTask {
      return try await recoveryTask.value
    }
    let transcription = self.transcription
    let task = Task {
      try await transcription.recoverPending()
    }
    recoveryTask = task
    defer {
      recoveryTask = nil
    }
    let results = try await task.value
    for result in results {
      if case .success = result.result {
        if successfulRecoveryResults.count >= 32,
          let evictionKey = successfulRecoveryResults.keys.first
        {
          successfulRecoveryResults[evictionKey] = nil
        }
        successfulRecoveryResults[result.meetingID] = result
      }
    }
    return results
  }

  private func startLiveTranscription(for meetingID: MeetingID) {
    guard liveTasks[meetingID] == nil else {
      return
    }
    let capture = self.capture
    let speech = self.speech
    let localeIdentifier = self.localeIdentifier
    liveTasks[meetingID] = Task { [weak self] in
      while !Task.isCancelled {
        do {
          let frames = await capture.liveFrames(meetingID: meetingID)
          let results = try await speech.liveResults(
            frames: frames,
            localeIdentifier: localeIdentifier
          )
          for try await event in results {
            try Task.checkCancellation()
            await self?.receive(event, meetingID: meetingID)
          }
          return
        } catch is CancellationError {
          return
        } catch TranscriptError.speechAssetsUnavailable {
          // Speech assets may become available after recording starts. Keep
          // retrying live results while durable audio capture continues.
          try? await Task.sleep(for: .milliseconds(500))
        } catch {
          return
        }
      }
    }
  }

  private func receive(
    _ event: SpeechRecognitionEvent,
    meetingID: MeetingID
  ) {
    var snapshot = liveSnapshots[meetingID] ?? LiveTranscriptSnapshot()
    switch event.stability {
    case .volatile:
      snapshot = LiveTranscriptSnapshot(
        finalSegments: snapshot.finalSegments,
        volatileSegment: event.segment
      )
    case .final:
      var finals = snapshot.finalSegments
      if !finals.contains(event.segment) {
        appendBounded(event.segment, to: &finals)
      }
      snapshot = LiveTranscriptSnapshot(
        finalSegments: finals,
        volatileSegment: nil
      )
    }
    liveSnapshots[meetingID] = snapshot
    for observer in observers[meetingID]?.values ?? [:].values {
      observer.yield(snapshot)
    }
  }

  private func stopLiveTranscription(meetingID: MeetingID) {
    liveTasks.removeValue(forKey: meetingID)?.cancel()
  }

  private func finishObservers(meetingID: MeetingID) {
    for observer in observers.removeValue(forKey: meetingID)?.values ?? [:].values {
      observer.finish()
    }
    liveSnapshots[meetingID] = nil
  }

  private func removeObserver(meetingID: MeetingID, observerID: UUID) {
    observers[meetingID]?[observerID] = nil
    if observers[meetingID]?.isEmpty == true {
      observers[meetingID] = nil
    }
  }

  private func appendBounded(
    _ candidate: TranscriptSegmentCandidate,
    to candidates: inout [TranscriptSegmentCandidate]
  ) {
    candidates.append(candidate)
    let overflow = candidates.count - maxLiveTranscriptSegments
    if overflow > 0 {
      candidates.removeFirst(overflow)
    }
  }

}
