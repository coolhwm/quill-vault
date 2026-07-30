import Domain
import Foundation

public actor AudioCaptureEngine: AudioCapture {
  typealias RecorderFactory = @Sendable () -> any AudioRecorderDriving

  private struct ActiveCapture {
    let session: RecordingSession
    let reservation: RecordingFileReservation
    let continuation: RecordingContinuationReservation?
    let continuationOffsetSeconds: Double?
    let recorder: any AudioRecorderDriving
    var hasStopped: Bool
  }

  private let files: any RecordingFileStore
  private let permission: any MicrophonePermissionAuthorizing
  private let makeRecorder: RecorderFactory
  private let validator: any RecordedAudioValidating
  private let merger: any RecordedAudioMerging
  private var startingMeetingID: MeetingID?
  private var activeCapture: ActiveCapture?
  private var completedRecordings: [MeetingID: RecordedAudio] = [:]
  private var interruptedRecordings: [MeetingID: RecordedAudio] = [:]
  private var captureEventTasks: [MeetingID: Task<[RecordingCaptureEvent], Never>] = [:]
  private var pendingCaptureEvents: [MeetingID: [RecordingCaptureEvent]] = [:]
  private var captureEventObservers:
    [MeetingID: [UInt64: AsyncStream<RecordingCaptureEvent>.Continuation]] = [:]
  private var nextCaptureEventObserverID: UInt64 = 0

  public init(fileStore: any RecordingFileStore) {
    files = fileStore
    permission = SystemMicrophonePermissionAuthorizer()
    makeRecorder = { AVAudioEngineRecorderDriver() }
    validator = AVRecordedAudioValidator()
    merger = AVRecordedAudioMerger()
  }

  init(
    files: any RecordingFileStore,
    permission: any MicrophonePermissionAuthorizing,
    makeRecorder: @escaping RecorderFactory,
    validator: any RecordedAudioValidating,
    merger: any RecordedAudioMerging = AVRecordedAudioMerger()
  ) {
    self.files = files
    self.permission = permission
    self.makeRecorder = makeRecorder
    self.validator = validator
    self.merger = merger
  }

  public func start(_ session: RecordingSession) async throws -> Date {
    guard activeCapture == nil, startingMeetingID == nil else {
      throw RecordingError.alreadyRecording
    }
    startingMeetingID = session.meetingID
    guard await permission.requestPermission() else {
      startingMeetingID = nil
      throw RecordingError.microphonePermissionDenied
    }
    do {
      try Task.checkCancellation()
    } catch {
      startingMeetingID = nil
      throw error
    }

    let reservation: RecordingFileReservation
    do {
      reservation = try await files.reserveRecording(for: session)
    } catch {
      startingMeetingID = nil
      throw map(error, fallback: .authoritativeDirectoryUnavailable)
    }

    let recorder = makeRecorder()
    do {
      let startedAt = try await recorder.start(at: reservation.recordingURL)
      try Task.checkCancellation()
      try await files.publishRecordingStart(
        reservation,
        startedAt: startedAt
      )
      let acknowledgedSession = RecordingSession(
        meetingID: session.meetingID,
        startedAt: startedAt
      )
      activeCapture = ActiveCapture(
        session: acknowledgedSession,
        reservation: reservation,
        continuation: nil,
        continuationOffsetSeconds: nil,
        recorder: recorder,
        hasStopped: false
      )
      observeCaptureEvents(
        from: recorder,
        meetingID: session.meetingID
      )
      startingMeetingID = nil
      return startedAt
    } catch is CancellationError {
      startingMeetingID = nil
      recorder.stop()
      await files.cancelRecording(meetingID: session.meetingID)
      throw CancellationError()
    } catch {
      startingMeetingID = nil
      recorder.stop()
      await files.cancelRecording(meetingID: session.meetingID)
      throw map(error, fallback: .captureCouldNotStart)
    }
  }

  public func stop(meetingID: MeetingID) async throws -> RecordedAudio {
    if let completed = completedRecordings[meetingID] {
      return completed
    }
    guard var active = activeCapture, active.session.meetingID == meetingID else {
      throw RecordingError.noActiveRecording
    }

    if !active.hasStopped {
      active.recorder.stop()
      active.hasStopped = true
      activeCapture = active
      pendingCaptureEvents[meetingID] =
        await captureEventTasks.removeValue(forKey: meetingID)?.value ?? []
      finishCaptureEventObservers(meetingID: meetingID)
    }
    do {
      for event in pendingCaptureEvents[meetingID] ?? [] {
        try await files.recordCaptureEvent(event, meetingID: meetingID)
      }
      pendingCaptureEvents[meetingID] = nil
    } catch {
      throw map(error, fallback: .recordingWriteFailed)
    }

    let audio: RecordedAudio
    let validationURL: URL
    if let continuation = active.continuation {
      do {
        let continuationAudio = try validator.validate(
          continuation.continuationURL
        )
        guard continuationAudio.isValid else {
          throw RecordingError.invalidRecordedAudio
        }
        try await merger.merge(
          originalURL: continuation.originalRecordingURL,
          continuationURL: continuation.continuationURL,
          candidateURL: continuation.candidateURL
        )
        let candidateAudio = try validator.validate(
          continuation.candidateURL
        )
        guard candidateAudio.isValid else {
          throw RecordingError.invalidRecordedAudio
        }
        try await files.commitRecordingContinuation(continuation)
        validationURL = continuation.originalRecordingURL
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw map(error, fallback: .recordingWriteFailed)
      }
    } else {
      validationURL = active.reservation.recordingURL
    }

    do {
      audio = try validator.validate(validationURL)
    } catch {
      if active.continuation == nil {
        await files.abandonRecording(meetingID: meetingID)
        activeCapture = nil
      }
      throw map(error, fallback: .invalidRecordedAudio)
    }
    guard audio.isValid else {
      if active.continuation == nil {
        await files.abandonRecording(meetingID: meetingID)
        activeCapture = nil
      }
      throw RecordingError.invalidRecordedAudio
    }

    do {
      try await files.finishRecording(meetingID: meetingID)
    } catch {
      throw map(error, fallback: .recordingWriteFailed)
    }
    activeCapture = nil
    completedRecordings[meetingID] = audio
    pendingCaptureEvents[meetingID] = nil
    return audio
  }

  public func resumeInterrupted(
    _ session: RecordingSession
  ) async throws -> Date {
    guard activeCapture == nil, startingMeetingID == nil else {
      throw RecordingError.alreadyRecording
    }
    guard let inspectedAudio = try await recoverInterrupted(session) else {
      throw RecordingError.invalidRecordedAudio
    }

    startingMeetingID = session.meetingID
    guard await permission.requestPermission() else {
      startingMeetingID = nil
      throw RecordingError.microphonePermissionDenied
    }

    let continuation: RecordingContinuationReservation
    do {
      continuation = try await files.reserveRecordingContinuation(
        for: session
      )
    } catch {
      startingMeetingID = nil
      throw map(error, fallback: .recordingWriteFailed)
    }

    let recorder = makeRecorder()
    do {
      let resumedAt = try await recorder.start(
        at: continuation.continuationURL
      )
      try await files.recordCaptureEvent(
        .interruptionEnded(at: resumedAt, didResume: true),
        meetingID: session.meetingID
      )
      activeCapture = ActiveCapture(
        session: session,
        reservation: RecordingFileReservation(
          meetingID: session.meetingID,
          createdAt: session.startedAt,
          directoryURL: continuation.originalRecordingURL
            .deletingLastPathComponent(),
          recordingURL: continuation.originalRecordingURL
        ),
        continuation: continuation,
        continuationOffsetSeconds: inspectedAudio.durationSeconds,
        recorder: recorder,
        hasStopped: false
      )
      interruptedRecordings[session.meetingID] = nil
      observeCaptureEvents(
        from: recorder,
        meetingID: session.meetingID
      )
      startingMeetingID = nil
      return resumedAt
    } catch is CancellationError {
      recorder.stop()
      await files.cancelRecordingContinuation(continuation)
      startingMeetingID = nil
      throw CancellationError()
    } catch {
      recorder.stop()
      await files.cancelRecordingContinuation(continuation)
      startingMeetingID = nil
      throw map(error, fallback: .captureCouldNotStart)
    }
  }

  public func recoverInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio? {
    guard
      let reservation = try await files.recoverInterruptedRecording(for: session)
    else {
      return nil
    }

    do {
      if let continuation = try await files.recoverRecordingContinuation(
        for: session
      ) {
        if FileManager.default.fileExists(
          atPath: continuation.candidateURL.path
        ) {
          let candidateAudio = try validator.validate(
            continuation.candidateURL
          )
          guard candidateAudio.isValid else {
            throw RecordingError.invalidRecordedAudio
          }
        } else {
          let continuationAudio = try validator.validate(
            continuation.continuationURL
          )
          guard continuationAudio.isValid else {
            throw RecordingError.invalidRecordedAudio
          }
          try await merger.merge(
            originalURL: continuation.originalRecordingURL,
            continuationURL: continuation.continuationURL,
            candidateURL: continuation.candidateURL
          )
          let candidateAudio = try validator.validate(
            continuation.candidateURL
          )
          guard candidateAudio.isValid else {
            throw RecordingError.invalidRecordedAudio
          }
        }
        try await files.commitRecordingContinuation(continuation)
      }
    } catch let error as RecordingError
      where error == .invalidRecordedAudio
    {
      if let continuation = try? await files.recoverRecordingContinuation(
        for: session
      ) {
        await files.quarantineRecordingContinuation(continuation)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw map(error, fallback: .recordingWriteFailed)
    }

    let audio: RecordedAudio
    do {
      audio = try validator.validate(reservation.recordingURL)
    } catch is CancellationError {
      await files.abandonRecording(meetingID: session.meetingID)
      throw CancellationError()
    } catch let error as RecordingError
      where error == .invalidRecordedAudio
    {
      await files.abandonRecording(meetingID: session.meetingID)
      return nil
    } catch {
      throw map(error, fallback: .recordingWriteFailed)
    }
    guard audio.isValid else {
      await files.abandonRecording(meetingID: session.meetingID)
      return nil
    }

    interruptedRecordings[session.meetingID] = audio
    return audio
  }

  public func finishInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio {
    guard let audio = try await recoverInterrupted(session) else {
      throw RecordingError.invalidRecordedAudio
    }

    do {
      try await files.finishRecording(meetingID: session.meetingID)
      interruptedRecordings[session.meetingID] = nil
      completedRecordings[session.meetingID] = audio
      return audio
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw map(error, fallback: .recordingWriteFailed)
    }
  }

  public func liveFrames(
    meetingID: MeetingID
  ) async -> AsyncStream<AudioFrame> {
    guard
      let activeCapture,
      activeCapture.session.meetingID == meetingID,
      !activeCapture.hasStopped
    else {
      return AsyncStream { $0.finish() }
    }
    return activeCapture.recorder.frames()
  }

  public func captureEvents(
    meetingID: MeetingID
  ) async -> AsyncStream<RecordingCaptureEvent> {
    guard
      let activeCapture,
      activeCapture.session.meetingID == meetingID,
      !activeCapture.hasStopped
    else {
      return AsyncStream { $0.finish() }
    }
    let pair = AsyncStream<RecordingCaptureEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(8)
    )
    let observerID = nextCaptureEventObserverID
    nextCaptureEventObserverID &+= 1
    captureEventObservers[meetingID, default: [:]][observerID] =
      pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
      Task {
        await self?.removeCaptureEventObserver(
          meetingID: meetingID,
          observerID: observerID
        )
      }
    }
    return pair.stream
  }

  public func recordingCaptureEvents(
    meetingID: MeetingID
  ) async throws -> [RecordingCaptureEvent] {
    try await files.recordingCaptureEvents(meetingID: meetingID)
  }

  public func activeRecordingAudioSegments(
    meetingID: MeetingID
  ) async -> [ActiveRecordingAudioSegment] {
    guard
      let activeCapture,
      activeCapture.session.meetingID == meetingID,
      !activeCapture.hasStopped
    else {
      return []
    }
    guard
      let continuation = activeCapture.continuation,
      let continuationOffset = activeCapture.continuationOffsetSeconds
    else {
      return [
        ActiveRecordingAudioSegment(
          fileURL: activeCapture.reservation.recordingURL,
          timelineOffsetSeconds: 0
        )
      ]
    }
    return [
      ActiveRecordingAudioSegment(
        fileURL: continuation.originalRecordingURL,
        timelineOffsetSeconds: 0
      ),
      ActiveRecordingAudioSegment(
        fileURL: continuation.continuationURL,
        timelineOffsetSeconds: continuationOffset
      ),
    ]
  }

  public func cancel(meetingID: MeetingID) async {
    guard
      let active = activeCapture,
      active.session.meetingID == meetingID
    else {
      await files.cancelRecording(meetingID: meetingID)
      return
    }
    active.recorder.stop()
    _ = await captureEventTasks.removeValue(forKey: meetingID)?.value
    activeCapture = nil
    completedRecordings[meetingID] = nil
    pendingCaptureEvents[meetingID] = nil
    finishCaptureEventObservers(meetingID: meetingID)
    if let continuation = active.continuation {
      await files.cancelRecordingContinuation(continuation)
    } else {
      await files.cancelRecording(meetingID: meetingID)
    }
  }

  private func map(
    _ error: any Error,
    fallback: RecordingError
  ) -> RecordingError {
    return error as? RecordingError ?? fallback
  }

  private func observeCaptureEvents(
    from recorder: any AudioRecorderDriving,
    meetingID: MeetingID
  ) {
    let files = self.files
    captureEventTasks[meetingID] = Task {
      var failedEvents: [RecordingCaptureEvent] = []
      for await event in recorder.events() {
        self.broadcastCaptureEvent(event, meetingID: meetingID)
        do {
          try await files.recordCaptureEvent(
            event,
            meetingID: meetingID
          )
        } catch {
          failedEvents.append(event)
        }
      }
      return failedEvents
    }
  }

  private func broadcastCaptureEvent(
    _ event: RecordingCaptureEvent,
    meetingID: MeetingID
  ) {
    for continuation in captureEventObservers[meetingID]?.values ?? [:].values {
      continuation.yield(event)
    }
  }

  private func removeCaptureEventObserver(
    meetingID: MeetingID,
    observerID: UInt64
  ) {
    captureEventObservers[meetingID]?[observerID] = nil
    if captureEventObservers[meetingID]?.isEmpty == true {
      captureEventObservers[meetingID] = nil
    }
  }

  private func finishCaptureEventObservers(meetingID: MeetingID) {
    for continuation in captureEventObservers.removeValue(forKey: meetingID)?.values ?? [:].values {
      continuation.finish()
    }
  }
}
