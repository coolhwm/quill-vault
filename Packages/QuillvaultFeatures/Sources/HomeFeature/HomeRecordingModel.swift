import Application
import Domain
import Foundation
import Observation

public enum HomeRecordingState: Equatable, Sendable {
  case idle
  case starting
  case recording(RecordingSession)
  case finishing(RecordingSession)
  case finishFailed(RecordingSession, RecordingError)
  case interrupted(RecordingSession, RecordedAudio)
  case completed(RecordingCompletion)
  case startFailed(RecordingError)
}

public enum HomeDirectoryState: Equatable, Sendable {
  case checking
  case recoveryRequired(AuthoritativeDirectoryRecovery)
  case authorized(AuthoritativeDirectory)
}

public enum TranscriptRecoveryState: Equatable, Sendable {
  case idle
  case retrying
  case failed(TranscriptError)
}

/// Post-recording processing projected on the home result card.
public enum HomeProcessingPhase: Equatable, Sendable {
  case idle
  case finalizingTranscript
  case transcriptFailed(TranscriptError)
  case awaitingMinutes
  case generatingMinutes(GenerationSnapshot)
  case generationPaused(GenerationSnapshot)
  case minutesCompleted
  case generationFailed
}

public enum HomeCaptureStatus: Equatable, Sendable {
  case active
  case interrupted(RecordingInterruptionReason)
  case resumeFailed
}

@MainActor
@Observable
public final class HomeRecordingModel {
  public private(set) var state: HomeRecordingState = .idle
  public private(set) var directoryState: HomeDirectoryState = .checking
  public private(set) var liveTranscriptText = ""
  public private(set) var liveTranscriptLatestLineID = "empty"
  /// When true, the recording transcript view should keep the latest line visible.
  public private(set) var isLiveTranscriptPinnedToBottom = true
  public private(set) var transcriptRecoveryState: TranscriptRecoveryState = .idle
  public private(set) var processingPhase: HomeProcessingPhase = .idle
  public private(set) var focusedMeetingID: MeetingID?
  public private(set) var captureStatus: HomeCaptureStatus = .active
  public private(set) var interruptionGaps: [RecordingInterruptionGap] = []
  public var isRecordingNoticePresented = false

  private let recording: any RecordingUseCase
  private let directory: any AuthoritativeDirectoryUseCase
  private let quickStart: any RecordingQuickStartUseCase
  private let library: (any MeetingLibraryUseCase)?
  private let generation: (any GenerationUseCase)?
  private let modelProfiles: (any ModelProfileUseCase)?
  private var liveTranscriptTask: Task<Void, Never>?
  private var captureEventTask: Task<Void, Never>?
  private var postRecordingTask: Task<Void, Never>?
  private var generationPollTask: Task<Void, Never>?
  private var captureEvents: [RecordingCaptureEvent] = []
  private var isFinalizingTranscript = false
  private var isStartingMinutes = false

  public init(
    recording: any RecordingUseCase,
    directory: any AuthoritativeDirectoryUseCase,
    quickStart: (any RecordingQuickStartUseCase)? = nil,
    library: (any MeetingLibraryUseCase)? = nil,
    generation: (any GenerationUseCase)? = nil,
    modelProfiles: (any ModelProfileUseCase)? = nil
  ) {
    self.recording = recording
    self.directory = directory
    self.quickStart =
      quickStart
      ?? RecordingQuickStartWorkflow(
        recording: recording,
        directory: directory
      )
    self.library = library
    self.generation = generation
    self.modelProfiles = modelProfiles
  }

  public var isSessionPresented: Bool {
    switch state {
    case .recording, .finishing, .finishFailed:
      return true
    case .idle, .starting, .interrupted, .completed, .startFailed:
      return false
    }
  }

  public func restore() async {
    guard state == .idle else {
      return
    }
    await restoreDirectory()
    if let outcome = await quickStart.restore() {
      presentQuickStartOutcome(outcome)
    }
    guard !isSessionPresented else {
      return
    }
    await restoreProcessingState()
  }

  public func start() async {
    guard !isSessionPresented, state != .starting else {
      return
    }
    cancelPostRecordingWork()
    captureEvents = []
    interruptionGaps = []
    processingPhase = .idle
    focusedMeetingID = nil
    transcriptRecoveryState = .idle
    state = .starting
    presentQuickStartOutcome(await quickStart.start())
  }

  public func presentQuickStartOutcome(
    _ outcome: RecordingQuickStartOutcome
  ) {
    switch outcome {
    case .started(let snapshot), .alreadyActive(let snapshot),
      .requiresInterruptedDecision(let snapshot):
      present(snapshot)
    case .requiresAppAttention(.recordingNotice):
      state = .idle
      isRecordingNoticePresented = true
    case .requiresAppAttention(.microphonePermission):
      state = .startFailed(.microphonePermissionDenied)
    case .requiresAppAttention(.authoritativeDirectory(let recovery)):
      directoryState = .recoveryRequired(recovery)
      state = .startFailed(.authoritativeDirectoryUnavailable)
    case .requiresAppAttention(.insufficientStorage):
      state = .startFailed(.insufficientStorage)
    case .requiresAppAttention(.retry):
      state = .startFailed(.captureCouldNotStart)
    case .alreadyStarting, .cancelled:
      if state == .starting {
        state = .idle
      }
    }
  }

  public func selectDirectory(opaqueReference: String) async {
    directoryState = .checking
    do {
      let authorized = try await directory.authorize(
        AuthoritativeDirectorySelection(
          opaqueReference: opaqueReference
        )
      )
      directoryState = .authorized(authorized)
    } catch {
      directoryState = .recoveryRequired(recovery(for: error))
    }
  }

  public func refreshDirectory() async {
    await restoreDirectory()
  }

  public func catchUpLiveTranscript() async {
    guard case .recording = state else {
      return
    }
    await recording.catchUpLiveTranscript()
  }

  /// Updates whether the live transcript should auto-follow new lines.
  /// Callers pass scroll metrics from the recording transcript list.
  public func updateLiveTranscriptPin(
    offsetY: CGFloat,
    contentHeight: CGFloat,
    visibleHeight: CGFloat,
    threshold: CGFloat = 48
  ) {
    let distanceFromBottom = contentHeight - visibleHeight - offsetY
    isLiveTranscriptPinnedToBottom = distanceFromBottom <= threshold
  }

  public func pinLiveTranscriptToBottom() {
    isLiveTranscriptPinnedToBottom = true
  }

  public func acknowledgeNoticeAndStart() async {
    isRecordingNoticePresented = false
    do {
      try await recording.acknowledgeRecordingNotice()
    } catch {
      state = .startFailed(.statePersistenceFailed)
      return
    }
    await start()
  }

  public func stop() async {
    let session: RecordingSession
    switch state {
    case .recording(let active), .finishFailed(let active, _):
      session = active
    case .idle, .starting, .finishing, .interrupted, .completed, .startFailed:
      return
    }
    state = .finishing(session)
    captureEventTask?.cancel()
    captureEventTask = nil

    do {
      let completion = try await recording.stop()
      presentCompleted(completion)
    } catch RecordingError.invalidRecordedAudio {
      state = .startFailed(.invalidRecordedAudio)
      processingPhase = .idle
    } catch let error as RecordingError {
      state = .finishFailed(session, error)
    } catch {
      state = .finishFailed(session, .recordingWriteFailed)
    }
  }

  public func finishInterrupted() async {
    guard case .interrupted(let session, let inspectedAudio) = state else {
      return
    }

    do {
      let completion = try await recording.finishInterrupted()
      presentCompleted(completion)
    } catch let error as RecordingError {
      state = .interrupted(session, inspectedAudio)
      processingPhase = .transcriptFailed(
        error == .invalidRecordedAudio
          ? .recordingUnavailable
          : .publicationFailed
      )
      transcriptRecoveryState = .failed(
        error == .invalidRecordedAudio
          ? .recordingUnavailable
          : .publicationFailed
      )
    } catch {
      state = .interrupted(session, inspectedAudio)
      processingPhase = .transcriptFailed(.publicationFailed)
      transcriptRecoveryState = .failed(.publicationFailed)
    }
  }

  public func resumeInterrupted() async {
    guard case .interrupted(let session, let inspectedAudio) = state else {
      return
    }

    do {
      let snapshot = try await recording.resumeInterrupted()
      state = .recording(snapshot.session)
      processingPhase = .idle
      transcriptRecoveryState = .idle
      observeLiveTranscript(for: snapshot.session.meetingID)
      observeCaptureEvents(for: snapshot.session.meetingID)
    } catch let error as RecordingError {
      state = .interrupted(session, inspectedAudio)
      processingPhase = .transcriptFailed(
        error == .invalidRecordedAudio
          ? .recordingUnavailable
          : .publicationFailed
      )
      transcriptRecoveryState = .failed(
        error == .invalidRecordedAudio
          ? .recordingUnavailable
          : .publicationFailed
      )
    } catch {
      state = .interrupted(session, inspectedAudio)
      processingPhase = .transcriptFailed(.publicationFailed)
      transcriptRecoveryState = .failed(.publicationFailed)
    }
  }

  public func startNewAfterInterruption() async {
    guard case .interrupted = state else {
      return
    }
    presentQuickStartOutcome(
      await quickStart.startNewAfterInterruption()
    )
  }

  /// Only available when transcript recovery actually failed.
  public func retryTranscript() async {
    guard
      case .completed(let completion) = state,
      completion.transcriptRevision == nil,
      case .transcriptFailed = processingPhase,
      !isFinalizingTranscript
    else {
      return
    }
    await finalizeTranscript(for: completion)
    guard
      case .completed(let recovered) = state,
      recovered.session.meetingID == completion.session.meetingID,
      recovered.transcriptRevision != nil
    else {
      return
    }
    await advanceAfterTranscriptReady(for: recovered)
  }

  /// Starts minutes when automatic generation is off or was skipped.
  public func startMinutesGeneration() async {
    guard
      case .completed(let completion) = state,
      completion.transcriptRevision != nil
    else {
      return
    }
    if case .generationPaused(let snapshot) = processingPhase {
      await resumeMinutesGeneration(
        jobID: snapshot.job.id,
        meetingID: completion.session.meetingID
      )
      return
    }
    guard
      processingPhase == .awaitingMinutes
        || processingPhase == .generationFailed
    else {
      return
    }
    await beginMinutesGeneration(for: completion.session.meetingID)
  }

  public func clearResult() {
    guard !isSessionPresented else {
      return
    }
    cancelPostRecordingWork()
    liveTranscriptTask?.cancel()
    liveTranscriptTask = nil
    liveTranscriptText = ""
    processingPhase = .idle
    focusedMeetingID = nil
    transcriptRecoveryState = .idle
    state = .idle
  }

  private func presentCompleted(_ completion: RecordingCompletion) {
    state = .completed(completion)
    focusedMeetingID = completion.session.meetingID
    transcriptRecoveryState = .idle
    if completion.transcriptRevision == nil {
      processingPhase = .finalizingTranscript
      schedulePostRecordingPipeline(for: completion)
    } else {
      processingPhase = .awaitingMinutes
      schedulePostRecordingPipeline(for: completion)
    }
  }

  private func schedulePostRecordingPipeline(for completion: RecordingCompletion) {
    postRecordingTask?.cancel()
    postRecordingTask = Task { [weak self] in
      await self?.runPostRecordingPipeline(for: completion)
    }
  }

  private func runPostRecordingPipeline(for completion: RecordingCompletion) async {
    guard case .completed(let current) = state,
      current.session.meetingID == completion.session.meetingID
    else {
      return
    }
    if current.transcriptRevision == nil {
      await finalizeTranscript(for: current)
    }
    guard
      case .completed(let withTranscript) = state,
      withTranscript.session.meetingID == completion.session.meetingID,
      withTranscript.transcriptRevision != nil
    else {
      return
    }
    await advanceAfterTranscriptReady(for: withTranscript)
  }

  private func finalizeTranscript(for completion: RecordingCompletion) async {
    guard !isFinalizingTranscript else {
      return
    }
    isFinalizingTranscript = true
    defer { isFinalizingTranscript = false }

    processingPhase = .finalizingTranscript
    transcriptRecoveryState = .retrying

    let results: [TranscriptionRecoveryResult]
    do {
      results = try await recording.recoverPendingTranscriptions()
    } catch is CancellationError {
      if case .finalizingTranscript = processingPhase {
        transcriptRecoveryState = .idle
      }
      return
    } catch {
      processingPhase = .transcriptFailed(.recognitionFailed)
      transcriptRecoveryState = .failed(.recognitionFailed)
      return
    }

    guard
      case .completed(let latest) = state,
      latest.session.meetingID == completion.session.meetingID
    else {
      return
    }

    guard
      let recovery = results.first(
        where: { $0.meetingID == completion.session.meetingID }
      )
    else {
      processingPhase = .transcriptFailed(.recognitionFailed)
      transcriptRecoveryState = .failed(.recognitionFailed)
      return
    }

    switch recovery.result {
    case .success(let revision):
      state = .completed(
        RecordingCompletion(
          session: latest.session,
          audio: latest.audio,
          transcriptRevision: revision
        )
      )
      transcriptRecoveryState = .idle
    case .failure(let error):
      processingPhase = .transcriptFailed(error)
      transcriptRecoveryState = .failed(error)
    }
  }

  private func advanceAfterTranscriptReady(
    for completion: RecordingCompletion
  ) async {
    guard completion.transcriptRevision != nil else {
      return
    }
    let shouldAutoGenerate = await shouldAutomaticallyGenerateMinutes()
    if shouldAutoGenerate {
      await beginMinutesGeneration(for: completion.session.meetingID)
    } else {
      processingPhase = .awaitingMinutes
    }
  }

  private func shouldAutomaticallyGenerateMinutes() async -> Bool {
    guard generation != nil, modelProfiles != nil, library != nil else {
      return false
    }
    do {
      let collection = try await modelProfiles!.load()
      guard collection.automaticGeneration.isEnabled else {
        return false
      }
      guard let currentID = collection.currentProfileID else {
        return false
      }
      return collection.profiles.contains {
        $0.id == currentID && $0.isUsable
      }
    } catch {
      return false
    }
  }

  private func beginMinutesGeneration(for meetingID: MeetingID) async {
    guard
      let generation,
      let library,
      case .authorized(let directory) = directoryState,
      !isStartingMinutes
    else {
      processingPhase = .awaitingMinutes
      return
    }
    isStartingMinutes = true
    defer { isStartingMinutes = false }

    let meeting: MeetingIndexEntry
    do {
      meeting = try await resolveMeeting(
        meetingID: meetingID,
        library: library
      )
    } catch {
      processingPhase = .awaitingMinutes
      return
    }

    startGenerationPolling(meetingID: meetingID)

    do {
      let snapshot = try await generation.start(
        in: directory,
        meeting: meeting
      )
      applyGenerationSnapshot(snapshot)
      if snapshot.job.state != .running && snapshot.job.state != .pending {
        generationPollTask?.cancel()
        generationPollTask = nil
      }
    } catch GenerationWorkflowError.activeJobExists {
      if let existing = try? await generation.load(meetingID: meetingID) {
        applyGenerationSnapshot(existing)
      } else {
        processingPhase = .generationFailed
      }
    } catch {
      processingPhase = .generationFailed
      generationPollTask?.cancel()
      generationPollTask = nil
    }
  }

  private func resumeMinutesGeneration(
    jobID: UUID,
    meetingID: MeetingID
  ) async {
    guard
      let generation,
      let library,
      case .authorized(let directory) = directoryState,
      !isStartingMinutes
    else {
      return
    }
    isStartingMinutes = true
    defer { isStartingMinutes = false }

    let meeting: MeetingIndexEntry
    do {
      meeting = try await resolveMeeting(
        meetingID: meetingID,
        library: library
      )
    } catch {
      processingPhase = .generationFailed
      return
    }

    startGenerationPolling(meetingID: meetingID)
    do {
      let snapshot = try await generation.resume(
        jobID,
        in: directory,
        meeting: meeting
      )
      applyGenerationSnapshot(snapshot)
      if snapshot.job.state != .running && snapshot.job.state != .pending {
        generationPollTask?.cancel()
        generationPollTask = nil
      }
    } catch {
      processingPhase = .generationFailed
      generationPollTask?.cancel()
      generationPollTask = nil
    }
  }

  private func resolveMeeting(
    meetingID: MeetingID,
    library: any MeetingLibraryUseCase
  ) async throws -> MeetingIndexEntry {
    if let snapshot = try? await library.synchronize(),
      let meeting = snapshot.meetings.first(where: { $0.id == meetingID })
    {
      return meeting
    }
    let rebuilt = try await library.rebuild()
    guard let meeting = rebuilt.meetings.first(where: { $0.id == meetingID })
    else {
      throw GenerationWorkflowError.transcriptNotReady
    }
    return meeting
  }

  private func startGenerationPolling(meetingID: MeetingID) {
    generationPollTask?.cancel()
    guard let generation else {
      return
    }
    generationPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard let self, !Task.isCancelled else {
          return
        }
        do {
          if let snapshot = try await generation.load(meetingID: meetingID) {
            self.applyGenerationSnapshot(snapshot)
            switch snapshot.job.state {
            case .completed, .superseded:
              return
            case .pending, .running, .paused:
              continue
            }
          }
        } catch {
          return
        }
      }
    }
  }

  private func applyGenerationSnapshot(_ snapshot: GenerationSnapshot) {
    focusedMeetingID = snapshot.job.meetingID
    switch snapshot.job.state {
    case .pending, .running:
      processingPhase = .generatingMinutes(snapshot)
    case .paused:
      processingPhase = .generationPaused(snapshot)
    case .completed:
      processingPhase = .minutesCompleted
    case .superseded:
      processingPhase = .awaitingMinutes
    }
  }

  private func restoreProcessingState() async {
    // Prefer restoring an active generation job for a recent meeting.
    if let generation, let library,
      let snapshot = try? await library.restore()
    {
      for meeting in snapshot.meetings {
        if let job = try? await generation.load(meetingID: meeting.id),
          job.job.isActive
        {
          presentRestoredMeeting(meeting, revisionHint: nil)
          applyGenerationSnapshot(job)
          if job.job.state == .running || job.job.state == .pending {
            startGenerationPolling(meetingID: meeting.id)
          }
          return
        }
      }
    }

    // Finish any pending transcript recovery without requiring a retry tap.
    let results: [TranscriptionRecoveryResult]
    do {
      results = try await recording.recoverPendingTranscriptions()
    } catch {
      await restoreAwaitingMinutesIfNeeded()
      return
    }

    if let firstSuccess = results.first(where: {
      if case .success = $0.result { return true }
      return false
    }), case .success(let revision) = firstSuccess.result {
      let completion = RecordingCompletion(
        session: RecordingSession(
          meetingID: firstSuccess.meetingID,
          startedAt: Date()
        ),
        audio: RecordedAudio(
          durationSeconds: revision.timeline.audioDurationSeconds,
          packetCount: 0,
          byteCount: 0
        ),
        transcriptRevision: revision
      )
      focusedMeetingID = firstSuccess.meetingID
      state = .completed(completion)
      transcriptRecoveryState = .idle
      await advanceAfterTranscriptReady(for: completion)
      return
    }

    if let firstFailure = results.first(where: {
      if case .failure = $0.result { return true }
      return false
    }), case .failure(let error) = firstFailure.result {
      focusedMeetingID = firstFailure.meetingID
      processingPhase = .transcriptFailed(error)
      transcriptRecoveryState = .failed(error)
      state = .completed(
        RecordingCompletion(
          session: RecordingSession(
            meetingID: firstFailure.meetingID,
            startedAt: Date()
          ),
          audio: RecordedAudio(
            durationSeconds: 0.001,
            packetCount: 0,
            byteCount: 0
          )
        )
      )
      return
    }

    await restoreAwaitingMinutesIfNeeded()
  }

  private func restoreAwaitingMinutesIfNeeded() async {
    guard let library, let snapshot = try? await library.restore() else {
      processingPhase = .idle
      transcriptRecoveryState = .idle
      return
    }
    guard
      let meeting = snapshot.meetings.first(where: {
        $0.status == .awaitingMinutes
      })
    else {
      processingPhase = .idle
      transcriptRecoveryState = .idle
      return
    }
    presentRestoredMeeting(meeting, revisionHint: nil)
    let shouldAutoGenerate = await shouldAutomaticallyGenerateMinutes()
    if shouldAutoGenerate {
      await beginMinutesGeneration(for: meeting.id)
    } else {
      processingPhase = .awaitingMinutes
    }
  }

  private func presentRestoredMeeting(
    _ meeting: MeetingIndexEntry,
    revisionHint: TranscriptRevision?
  ) {
    let duration = max(meeting.durationSeconds ?? 0.001, 0.001)
    let revision =
      revisionHint
      ?? (meeting.assets.contains(.transcript)
        ? TranscriptRevision(
          meetingID: meeting.id,
          localeIdentifier: "und",
          timeline: TranscriptTimeline(
            audioDurationSeconds: duration,
            segments: []
          )
        )
        : nil)
    focusedMeetingID = meeting.id
    state = .completed(
      RecordingCompletion(
        session: RecordingSession(
          meetingID: meeting.id,
          startedAt: meeting.createdAt
        ),
        audio: RecordedAudio(
          durationSeconds: duration,
          packetCount: 0,
          byteCount: 0
        ),
        transcriptRevision: revision
      )
    )
    transcriptRecoveryState = .idle
  }

  private func cancelPostRecordingWork() {
    postRecordingTask?.cancel()
    postRecordingTask = nil
    generationPollTask?.cancel()
    generationPollTask = nil
    isFinalizingTranscript = false
    isStartingMinutes = false
  }

  private func observeCaptureEvents(for meetingID: MeetingID) {
    captureEventTask?.cancel()
    captureStatus = .active
    captureEventTask = Task { [weak self, recording] in
      let events = await recording.captureEvents(meetingID: meetingID)
      for await event in events {
        guard !Task.isCancelled else {
          return
        }
        self?.captureEvents.append(event)
        if let captureEvents = self?.captureEvents {
          self?.interruptionGaps = RecordingCaptureTimeline.gaps(
            in: captureEvents
          )
        }
        switch event {
        case .interruptionBegan(_, let reason):
          self?.captureStatus = .interrupted(reason)
        case .interruptionEnded(_, let didResume):
          self?.captureStatus = didResume ? .active : .resumeFailed
        }
      }
    }
  }

  private func present(_ snapshot: RecordingSnapshot) {
    captureEvents = snapshot.captureEvents
    interruptionGaps = RecordingCaptureTimeline.gaps(in: captureEvents)
    switch snapshot.activity {
    case .recording:
      state = .recording(snapshot.session)
      observeLiveTranscript(for: snapshot.session.meetingID)
      observeCaptureEvents(for: snapshot.session.meetingID)
    case .finishing:
      state = .finishing(snapshot.session)
    case .interrupted(let audio):
      state = .interrupted(snapshot.session, audio)
    }
  }

  private func observeLiveTranscript(for meetingID: MeetingID) {
    liveTranscriptTask?.cancel()
    liveTranscriptText = ""
    liveTranscriptLatestLineID = "empty"
    isLiveTranscriptPinnedToBottom = true
    liveTranscriptTask = Task { [weak self, recording] in
      let snapshots = await recording.liveTranscript(meetingID: meetingID)
      for await snapshot in snapshots {
        guard !Task.isCancelled else {
          return
        }
        self?.liveTranscriptText = snapshot.displayText
        self?.liveTranscriptLatestLineID = snapshot.latestLineID
      }
    }
  }

  private func restoreDirectory() async {
    do {
      guard let authorized = try await directory.restore() else {
        directoryState = .recoveryRequired(.chooseDirectory)
        return
      }
      directoryState = .authorized(authorized)
    } catch {
      directoryState = .recoveryRequired(recovery(for: error))
    }
  }

  private func recovery(for error: Error) -> AuthoritativeDirectoryRecovery {
    (error as? DirectoryAccessError)?.recovery ?? .tryAgain
  }
}
