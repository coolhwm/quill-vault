import Application
import Domain
import Foundation
import Testing

@Suite("Transcribing recording use case")
struct TranscribingRecordingUseCaseTests {
  private let meetingID = MeetingID(
    rawValue: UUID(uuidString: "AC28DA31-21AB-44BF-B3D5-A7E1B1B7F2E9")!
  )

  @Test("Durable recording start returns without waiting for Speech")
  func speechCannotBlockRecordingStart() async throws {
    let base = RecordingUseCaseDouble(meetingID: meetingID)
    let speech = SpeechEngineDouble(livePreparationDelay: .seconds(5))
    let useCase = makeUseCase(base: base, speech: speech)

    let snapshot = try await useCase.start()

    #expect(snapshot.session.meetingID == meetingID)
    #expect(await base.startCount == 1)
    #expect(await speech.liveCallCount <= 1)
  }

  @Test("Volatile text is replaced while final text accumulates")
  func exposesLiveTranscript() async throws {
    let speech = SpeechEngineDouble(
      liveEvents: [
        event(0, 1, "临时一", .volatile),
        event(0, 1, "临时二", .volatile),
        event(0, 1, "最终", .final),
      ]
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      speech: speech
    )
    _ = try await useCase.start()
    let snapshots = await useCase.liveTranscript(meetingID: meetingID)

    var last: LiveTranscriptSnapshot?
    for await snapshot in snapshots {
      last = snapshot
      if snapshot.finalSegments.count == 1 {
        break
      }
    }

    #expect(last?.finalSegments.map(\.text) == ["最终"])
    #expect(last?.volatileSegment == nil)
  }

  @Test("Live transcript retains only a bounded recent window")
  func boundsLiveTranscript() async throws {
    let speech = SpeechEngineDouble(
      liveEvents: [
        event(0, 1, "一", .final),
        event(1, 2, "二", .final),
        event(2, 3, "三", .final),
      ]
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      speech: speech,
      maxLiveTranscriptSegments: 2
    )
    _ = try await useCase.start()
    let snapshots = await useCase.liveTranscript(meetingID: meetingID)

    var last: LiveTranscriptSnapshot?
    for await snapshot in snapshots {
      last = snapshot
      if snapshot.finalSegments.last?.text == "三" {
        break
      }
    }

    #expect(last?.finalSegments.map(\.text) == ["二", "三"])
  }

  @Test("Live transcription retries when Speech resources become available")
  func retriesLiveTranscriptionPreparation() async throws {
    let speech = SpeechEngineDouble(
      liveEvents: [event(0, 1, "资源已就绪", .final)],
      liveFailuresRemaining: 1
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      speech: speech
    )
    _ = try await useCase.start()
    let snapshots = await useCase.liveTranscript(meetingID: meetingID)

    var text = ""
    for await snapshot in snapshots {
      text = snapshot.displayText
      if !text.isEmpty {
        break
      }
    }

    #expect(text == "- [000.0–001.0] 资源已就绪")
    #expect(await speech.liveCallCount == 2)
  }

  @Test("Audio is stopped once and a failed transcript can be recovered")
  func retryUsesPersistedAudio() async throws {
    let base = RecordingUseCaseDouble(meetingID: meetingID)
    let recoveredRevision = revision(meetingID: meetingID)
    let transcription = TranscriptionUseCaseDouble(
      enqueueResults: [
        .failure(TranscriptError.publicationFailed),
        .success(()),
      ],
      recoveryResults: [
        TranscriptionRecoveryResult(
          meetingID: meetingID,
          result: .success(recoveredRevision)
        )
      ]
    )
    let useCase = makeUseCase(
      base: base,
      transcription: transcription
    )
    _ = try await useCase.start()

    let completion = try await useCase.stop()
    let recovery = try await useCase.recoverPendingTranscriptions()

    #expect(await base.stopCount == 1)
    #expect(await transcription.enqueueCount == 2)
    #expect(await transcription.finalizeCount == 0)
    #expect(completion.transcriptRevision == nil)
    #expect(
      recovery == [
        TranscriptionRecoveryResult(
          meetingID: meetingID,
          result: .success(recoveredRevision)
        )
      ])
  }

  @Test("A transcription failure completes recording without trapping the session")
  func transcriptionFailureDoesNotTrapRecording() async throws {
    let base = RecordingUseCaseDouble(meetingID: meetingID)
    let transcription = TranscriptionUseCaseDouble(
      enqueueResults: [
        .failure(
          TranscriptError.speechAssetsUnavailable("zh-CN")
        )
      ]
    )
    let useCase = makeUseCase(
      base: base,
      transcription: transcription
    )
    _ = try await useCase.start()

    let completion = try await useCase.stop()

    #expect(await base.stopCount == 1)
    #expect(completion.audio.durationSeconds == 10)
    #expect(completion.transcriptRevision == nil)
  }

  @Test("Ending an interrupted recording enqueues full-audio catch-up")
  func interruptedCompletionEnqueuesTranscription() async throws {
    let base = RecordingUseCaseDouble(meetingID: meetingID)
    let transcription = TranscriptionUseCaseDouble()
    let useCase = makeUseCase(
      base: base,
      transcription: transcription
    )

    let completion = try await useCase.finishInterrupted()

    #expect(completion.session.meetingID == meetingID)
    #expect(await base.finishInterruptedCount == 1)
    #expect(await transcription.enqueueCount == 1)
  }

  @Test("Continuing an interrupted recording restarts live transcription")
  func interruptedContinuationRestartsLiveTranscription() async throws {
    let base = RecordingUseCaseDouble(meetingID: meetingID)
    let speech = SpeechEngineDouble()
    let useCase = makeUseCase(base: base, speech: speech)

    let snapshot = try await useCase.resumeInterrupted()
    while await speech.liveCallCount == 0 {
      await Task.yield()
    }

    #expect(snapshot.activity == .recording)
    #expect(await base.resumeInterruptedCount == 1)
    #expect(await speech.liveCallCount == 1)
  }

  @Test("Stopping returns after durable enqueue without awaiting catch-up")
  func stopDoesNotAwaitCatchUp() async throws {
    let transcription = TranscriptionUseCaseDouble(
      recoveryDelay: .seconds(5)
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      transcription: transcription
    )
    _ = try await useCase.start()
    let clock = ContinuousClock()
    let startedAt = clock.now

    _ = try await useCase.stop()

    #expect(startedAt.duration(to: clock.now) < .seconds(1))
    #expect(await transcription.enqueueCount == 1)
    while await transcription.recoveryCount == 0 {
      await Task.yield()
    }
  }

  @Test("A completed background recovery remains visible to manual retry")
  func completedRecoveryIsRemembered() async throws {
    let recoveredRevision = revision(meetingID: meetingID)
    let transcription = TranscriptionUseCaseDouble(
      recoveryResults: [
        TranscriptionRecoveryResult(
          meetingID: meetingID,
          result: .success(recoveredRevision)
        )
      ]
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      transcription: transcription
    )
    _ = try await useCase.start()
    _ = try await useCase.stop()
    while await transcription.recoveryCount == 0 {
      await Task.yield()
    }
    await Task.yield()

    let results = try await useCase.recoverPendingTranscriptions()

    #expect(results.first?.result == .success(recoveredRevision))
  }

  @Test("Cold start launches recovery without blocking restore")
  func coldStartRecovery() async throws {
    let transcription = TranscriptionUseCaseDouble(
      recoveryDelay: .seconds(5)
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      transcription: transcription
    )

    _ = try await useCase.restore()

    while await transcription.recoveryCount == 0 {
      await Task.yield()
    }
    #expect(await transcription.recoveryCount == 1)
  }

  @Test("Returning to foreground catches live text up from durable audio")
  func foregroundCatchUpUsesRecordingFile() async throws {
    let recordingURL = URL(fileURLWithPath: "/tmp/active-recording.m4a")
    let capture = AudioCaptureDouble(
      activeSegments: [
        ActiveRecordingAudioSegment(
          fileURL: recordingURL,
          timelineOffsetSeconds: 0
        )
      ]
    )
    let speech = SpeechEngineDouble(
      fileEvents: [
        event(0, 1, "补齐一", .final),
        event(1, 2, "补齐二", .final),
        event(2, 3, "补齐三", .final),
      ]
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      capture: capture,
      speech: speech,
      maxLiveTranscriptSegments: 2
    )
    _ = try await useCase.start()

    await useCase.catchUpLiveTranscript()
    let snapshots = await useCase.liveTranscript(meetingID: meetingID)
    let snapshot = await snapshots.first { _ in true }

    #expect(snapshot?.finalSegments.map(\.text) == ["补齐二", "补齐三"])
    #expect(await speech.fileCallCount == 1)
    #expect(await speech.fileURLs == [recordingURL])
  }

  @Test("Foreground catch-up does not duplicate overlapping live finals")
  func foregroundCatchUpDedupesLiveOverlap() async throws {
    let recordingURL = URL(fileURLWithPath: "/tmp/active-recording.m4a")
    let speech = SpeechEngineDouble(
      liveEvents: [
        event(0, 1, "已确认", .final),
        event(1, 2, "继续讨论", .final),
      ],
      fileEvents: [
        event(0, 1.05, "已确认", .final),
        event(1.02, 2.1, "继续讨论", .final),
        event(2.1, 3, "补充内容", .final),
      ]
    )
    let useCase = makeUseCase(
      base: RecordingUseCaseDouble(meetingID: meetingID),
      capture: AudioCaptureDouble(
        activeSegments: [
          ActiveRecordingAudioSegment(
            fileURL: recordingURL,
            timelineOffsetSeconds: 0
          )
        ]
      ),
      speech: speech
    )
    _ = try await useCase.start()
    let snapshots = await useCase.liveTranscript(meetingID: meetingID)
    for await snapshot in snapshots {
      if snapshot.finalSegments.count == 2 {
        break
      }
    }

    await useCase.catchUpLiveTranscript()
    let after = await useCase.liveTranscript(meetingID: meetingID)
    let snapshot = await after.first { snapshot in
      snapshot.finalSegments.map(\.text).contains("补充内容")
    }

    #expect(snapshot?.finalSegments.map(\.text) == ["已确认", "继续讨论", "补充内容"])
  }

  @Test("Near-duplicate finals are not appended after catch-up")
  func nearDuplicateFinalsAreIgnored() {
    let existing = [
      TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "主题确认"),
      TranscriptSegmentCandidate(startSeconds: 1, endSeconds: 2, text: "行动项"),
    ]
    #expect(
      !LiveTranscriptDeduper.shouldAppend(
        TranscriptSegmentCandidate(startSeconds: 0.05, endSeconds: 1.02, text: "主题确认"),
        to: existing
      )
    )
    #expect(
      LiveTranscriptDeduper.shouldAppend(
        TranscriptSegmentCandidate(startSeconds: 2, endSeconds: 3, text: "新内容"),
        to: existing
      )
    )
  }

  private func makeUseCase(
    base: RecordingUseCaseDouble,
    capture: AudioCaptureDouble = AudioCaptureDouble(),
    speech: SpeechEngineDouble = SpeechEngineDouble(),
    transcription: TranscriptionUseCaseDouble = TranscriptionUseCaseDouble(),
    maxLiveTranscriptSegments: Int = 500
  ) -> TranscribingRecordingUseCase {
    TranscribingRecordingUseCase(
      recording: base,
      capture: capture,
      speech: speech,
      transcription: transcription,
      localeIdentifier: "zh-CN",
      maxLiveTranscriptSegments: maxLiveTranscriptSegments
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

  private func revision(meetingID: MeetingID) -> TranscriptRevision {
    TranscriptRevision(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(
        audioDurationSeconds: 10,
        segments: []
      )
    )
  }
}

private actor RecordingUseCaseDouble: RecordingUseCase {
  private let meetingID: MeetingID
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var resumeInterruptedCount = 0
  private(set) var finishInterruptedCount = 0

  init(meetingID: MeetingID) {
    self.meetingID = meetingID
  }

  func restore() -> RecordingSnapshot? {
    nil
  }

  func acknowledgeRecordingNotice() {}

  func catchUpLiveTranscript() {}

  func start() -> RecordingSnapshot {
    startCount += 1
    return RecordingSnapshot(session: session, activity: .recording)
  }

  func stop() -> RecordingCompletion {
    stopCount += 1
    return RecordingCompletion(
      session: session,
      audio: RecordedAudio(
        durationSeconds: 10,
        packetCount: 100,
        byteCount: 1_000,
        fileURL: URL(fileURLWithPath: "/tmp/recording.m4a")
      )
    )
  }

  func finishInterrupted() -> RecordingCompletion {
    finishInterruptedCount += 1
    return RecordingCompletion(
      session: session,
      audio: RecordedAudio(
        durationSeconds: 10,
        packetCount: 100,
        byteCount: 1_000,
        fileURL: URL(fileURLWithPath: "/tmp/recording.m4a")
      )
    )
  }

  func resumeInterrupted() -> RecordingSnapshot {
    resumeInterruptedCount += 1
    return RecordingSnapshot(session: session, activity: .recording)
  }

  func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    []
  }

  private var session: RecordingSession {
    RecordingSession(
      meetingID: meetingID,
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}

private actor AudioCaptureDouble: AudioCapture {
  private let activeSegments: [ActiveRecordingAudioSegment]

  init(activeSegments: [ActiveRecordingAudioSegment] = []) {
    self.activeSegments = activeSegments
  }

  func start(_ session: RecordingSession) -> Date {
    session.startedAt
  }

  func liveFrames(meetingID: MeetingID) -> AsyncStream<AudioFrame> {
    AsyncStream { continuation in
      continuation.yield(
        AudioFrame(
          samples: Data([0, 0, 0, 0]),
          sampleRate: 44_100,
          channelCount: 1,
          frameCount: 1,
          startSeconds: 0
        )
      )
      continuation.finish()
    }
  }

  func activeRecordingAudioSegments(
    meetingID: MeetingID
  ) -> [ActiveRecordingAudioSegment] {
    activeSegments
  }

  func recordingCaptureEvents(
    meetingID: MeetingID
  ) -> [RecordingCaptureEvent] {
    []
  }

  func stop(meetingID: MeetingID) -> RecordedAudio {
    RecordedAudio(durationSeconds: 1, packetCount: 1, byteCount: 1)
  }

  func cancel(meetingID: MeetingID) {}
}

private actor SpeechEngineDouble: SpeechTranscriptionEngine {
  private let liveEvents: [SpeechRecognitionEvent]
  private let fileEvents: [SpeechRecognitionEvent]
  private let livePreparationDelay: Duration?
  private var liveFailuresRemaining: Int
  private(set) var liveCallCount = 0
  private(set) var fileCallCount = 0
  private(set) var fileURLs: [URL] = []

  init(
    liveEvents: [SpeechRecognitionEvent] = [],
    fileEvents: [SpeechRecognitionEvent] = [],
    livePreparationDelay: Duration? = nil,
    liveFailuresRemaining: Int = 0
  ) {
    self.liveEvents = liveEvents
    self.fileEvents = fileEvents
    self.livePreparationDelay = livePreparationDelay
    self.liveFailuresRemaining = liveFailuresRemaining
  }

  func liveResults(
    frames: AsyncStream<AudioFrame>,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    liveCallCount += 1
    if liveFailuresRemaining > 0 {
      liveFailuresRemaining -= 1
      throw TranscriptError.speechAssetsUnavailable(localeIdentifier)
    }
    if let livePreparationDelay {
      try await Task.sleep(for: livePreparationDelay)
    }
    let events = liveEvents
    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }

  func fileResults(
    at recordingURL: URL,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    fileCallCount += 1
    fileURLs.append(recordingURL)
    let events = fileEvents
    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

private actor TranscriptionUseCaseDouble: TranscriptionUseCase {
  private var finalizeResults: [Result<TranscriptRevision, any Error>]
  private var enqueueResults: [Result<Void, any Error>]
  private var recoveryResults: [TranscriptionRecoveryResult]
  private let recoveryDelay: Duration?
  private(set) var finalizeCount = 0
  private(set) var enqueueCount = 0
  private(set) var recoveryCount = 0

  init(
    finalizeResults: [Result<TranscriptRevision, any Error>] = [],
    enqueueResults: [Result<Void, any Error>] = [],
    recoveryResults: [TranscriptionRecoveryResult] = [],
    recoveryDelay: Duration? = nil
  ) {
    self.finalizeResults = finalizeResults
    self.enqueueResults = enqueueResults
    self.recoveryResults = recoveryResults
    self.recoveryDelay = recoveryDelay
  }

  func enqueue(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) throws {
    enqueueCount += 1
    if !enqueueResults.isEmpty {
      try enqueueResults.removeFirst().get()
    }
  }

  func finalize(
    _ completion: RecordingCompletion,
    localeIdentifier: String
  ) throws -> TranscriptRevision {
    finalizeCount += 1
    if !finalizeResults.isEmpty {
      return try finalizeResults.removeFirst().get()
    }
    return TranscriptRevision(
      meetingID: completion.session.meetingID,
      localeIdentifier: localeIdentifier,
      timeline: TranscriptTimeline(
        audioDurationSeconds: completion.audio.durationSeconds,
        segments: []
      )
    )
  }

  func recoverPending() async -> [TranscriptionRecoveryResult] {
    recoveryCount += 1
    if let recoveryDelay {
      try? await Task.sleep(for: recoveryDelay)
    }
    let results = recoveryResults
    recoveryResults = []
    return results
  }
}
