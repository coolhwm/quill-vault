import Domain
import Foundation

public actor TranscribingRecordingUseCase: RecordingUseCase {
  private let recording: any RecordingUseCase
  private let capture: any AudioCapture
  private let speech: any SpeechTranscriptionEngine
  private let transcription: any TranscriptionUseCase
  private let localeIdentifier: String

  private var pendingCompletion: RecordingCompletion?
  private var liveTasks: [MeetingID: Task<Void, Never>] = [:]
  private var liveSnapshots: [MeetingID: LiveTranscriptSnapshot] = [:]
  private var observers: [MeetingID: [UUID: AsyncStream<LiveTranscriptSnapshot>.Continuation]] = [:]
  private var recoveryTask: Task<[TranscriptionRecoveryResult], Error>?
  private var successfulRecoveryResults: [MeetingID: TranscriptionRecoveryResult] = [:]
  private var didStartRecovery = false

  public init(
    recording: any RecordingUseCase,
    capture: any AudioCapture,
    speech: any SpeechTranscriptionEngine,
    transcription: any TranscriptionUseCase,
    localeIdentifier: String
  ) {
    self.recording = recording
    self.capture = capture
    self.speech = speech
    self.transcription = transcription
    self.localeIdentifier = localeIdentifier
  }

  public func restore() async throws -> RecordingSnapshot? {
    let snapshot = try await recording.restore()
    startRecoveryIfNeeded()
    if let snapshot, snapshot.activity == .recording {
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

  public func stop() async throws -> RecordingCompletion {
    let completion: RecordingCompletion
    if let pendingCompletion {
      completion = pendingCompletion
    } else {
      completion = try await recording.stop()
      pendingCompletion = completion
    }

    stopLiveTranscription(meetingID: completion.session.meetingID)
    var wasEnqueued = false
    do {
      try await transcription.enqueue(
        completion,
        localeIdentifier: localeIdentifier
      )
      pendingCompletion = nil
      wasEnqueued = true
    } catch is CancellationError {
      finishObservers(meetingID: completion.session.meetingID)
      throw CancellationError()
    } catch {
      // Keep the completion in memory so a manual retry can enqueue it
      // without stopping audio a second time.
    }
    finishObservers(meetingID: completion.session.meetingID)
    if wasEnqueued {
      startRecovery()
    }
    return completion
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
        finals.append(event.segment)
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

}
