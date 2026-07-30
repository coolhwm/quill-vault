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

  @Test("Audio is stopped once and a failed transcript can be retried")
  func retryUsesPersistedAudio() async throws {
    let base = RecordingUseCaseDouble(meetingID: meetingID)
    let transcription = TranscriptionUseCaseDouble(
      finalizeResults: [
        .failure(TranscriptError.publicationFailed),
        .success(revision(meetingID: meetingID)),
      ]
    )
    let useCase = makeUseCase(
      base: base,
      transcription: transcription
    )
    _ = try await useCase.start()

    await #expect(throws: RecordingError.transcriptPublicationFailed) {
      _ = try await useCase.stop()
    }
    let completion = try await useCase.stop()

    #expect(await base.stopCount == 1)
    #expect(await transcription.finalizeCount == 2)
    #expect(completion.transcriptRevision != nil)
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

  private func makeUseCase(
    base: RecordingUseCaseDouble,
    speech: SpeechEngineDouble = SpeechEngineDouble(),
    transcription: TranscriptionUseCaseDouble = TranscriptionUseCaseDouble()
  ) -> TranscribingRecordingUseCase {
    TranscribingRecordingUseCase(
      recording: base,
      capture: AudioCaptureDouble(),
      speech: speech,
      transcription: transcription,
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

  init(meetingID: MeetingID) {
    self.meetingID = meetingID
  }

  func restore() -> RecordingSnapshot? {
    nil
  }

  func acknowledgeRecordingNotice() {}

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

  private var session: RecordingSession {
    RecordingSession(
      meetingID: meetingID,
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}

private actor AudioCaptureDouble: AudioCapture {
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

  func stop(meetingID: MeetingID) -> RecordedAudio {
    RecordedAudio(durationSeconds: 1, packetCount: 1, byteCount: 1)
  }

  func cancel(meetingID: MeetingID) {}
}

private actor SpeechEngineDouble: SpeechTranscriptionEngine {
  private let liveEvents: [SpeechRecognitionEvent]
  private let livePreparationDelay: Duration?
  private(set) var liveCallCount = 0

  init(
    liveEvents: [SpeechRecognitionEvent] = [],
    livePreparationDelay: Duration? = nil
  ) {
    self.liveEvents = liveEvents
    self.livePreparationDelay = livePreparationDelay
  }

  func liveResults(
    frames: AsyncStream<AudioFrame>,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    liveCallCount += 1
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
    AsyncThrowingStream { $0.finish() }
  }
}

private actor TranscriptionUseCaseDouble: TranscriptionUseCase {
  private var finalizeResults: [Result<TranscriptRevision, any Error>]
  private let recoveryDelay: Duration?
  private(set) var finalizeCount = 0
  private(set) var recoveryCount = 0

  init(
    finalizeResults: [Result<TranscriptRevision, any Error>] = [],
    recoveryDelay: Duration? = nil
  ) {
    self.finalizeResults = finalizeResults
    self.recoveryDelay = recoveryDelay
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
    return []
  }
}
