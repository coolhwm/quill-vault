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
  public private(set) var transcriptRecoveryState: TranscriptRecoveryState = .idle
  public private(set) var captureStatus: HomeCaptureStatus = .active
  public private(set) var interruptionGaps: [RecordingInterruptionGap] = []
  public var isRecordingNoticePresented = false

  private let recording: any RecordingUseCase
  private let directory: any AuthoritativeDirectoryUseCase
  private let quickStart: any RecordingQuickStartUseCase
  private var liveTranscriptTask: Task<Void, Never>?
  private var captureEventTask: Task<Void, Never>?
  private var captureEvents: [RecordingCaptureEvent] = []

  public init(
    recording: any RecordingUseCase,
    directory: any AuthoritativeDirectoryUseCase,
    quickStart: (any RecordingQuickStartUseCase)? = nil
  ) {
    self.recording = recording
    self.directory = directory
    self.quickStart =
      quickStart
      ?? RecordingQuickStartWorkflow(
        recording: recording,
        directory: directory
      )
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
  }

  public func start() async {
    guard !isSessionPresented, state != .starting else {
      return
    }
    captureEvents = []
    interruptionGaps = []
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
      state = .completed(try await recording.stop())
      transcriptRecoveryState = .idle
    } catch RecordingError.invalidRecordedAudio {
      state = .startFailed(.invalidRecordedAudio)
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
      state = .completed(try await recording.finishInterrupted())
      transcriptRecoveryState = .idle
    } catch let error as RecordingError {
      state = .interrupted(session, inspectedAudio)
      transcriptRecoveryState = .failed(
        error == .invalidRecordedAudio
          ? .recordingUnavailable
          : .publicationFailed
      )
    } catch {
      state = .interrupted(session, inspectedAudio)
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
      transcriptRecoveryState = .idle
      observeLiveTranscript(for: snapshot.session.meetingID)
      observeCaptureEvents(for: snapshot.session.meetingID)
    } catch let error as RecordingError {
      state = .interrupted(session, inspectedAudio)
      transcriptRecoveryState = .failed(
        error == .invalidRecordedAudio
          ? .recordingUnavailable
          : .publicationFailed
      )
    } catch {
      state = .interrupted(session, inspectedAudio)
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

  public func retryTranscript() async {
    guard
      case .completed(let completion) = state,
      completion.transcriptRevision == nil,
      transcriptRecoveryState != .retrying
    else {
      return
    }

    transcriptRecoveryState = .retrying
    let results: [TranscriptionRecoveryResult]
    do {
      results = try await recording.recoverPendingTranscriptions()
    } catch is CancellationError {
      transcriptRecoveryState = .idle
      return
    } catch {
      transcriptRecoveryState = .failed(.recognitionFailed)
      return
    }
    guard
      let recovery = results.first(
        where: { $0.meetingID == completion.session.meetingID }
      )
    else {
      transcriptRecoveryState = .failed(.recognitionFailed)
      return
    }

    switch recovery.result {
    case .success(let revision):
      state = .completed(
        RecordingCompletion(
          session: completion.session,
          audio: completion.audio,
          transcriptRevision: revision
        )
      )
      transcriptRecoveryState = .idle
    case .failure(let error):
      transcriptRecoveryState = .failed(error)
    }
  }

  public func clearResult() {
    guard !isSessionPresented else {
      return
    }
    liveTranscriptTask?.cancel()
    liveTranscriptTask = nil
    liveTranscriptText = ""
    state = .idle
  }

  private func observeLiveTranscript(for meetingID: MeetingID) {
    liveTranscriptTask?.cancel()
    liveTranscriptText = ""
    liveTranscriptTask = Task { [weak self, recording] in
      let snapshots = await recording.liveTranscript(meetingID: meetingID)
      for await snapshot in snapshots {
        guard !Task.isCancelled else {
          return
        }
        self?.liveTranscriptText = snapshot.displayText
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
