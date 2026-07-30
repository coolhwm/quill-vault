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
  case completed(RecordingCompletion)
  case startFailed(RecordingError)
}

public enum HomeDirectoryState: Equatable, Sendable {
  case checking
  case recoveryRequired(AuthoritativeDirectoryRecovery)
  case authorized(AuthoritativeDirectory)
}

@MainActor
@Observable
public final class HomeRecordingModel {
  public private(set) var state: HomeRecordingState = .idle
  public private(set) var directoryState: HomeDirectoryState = .checking
  public private(set) var liveTranscriptText = ""
  public var isRecordingNoticePresented = false

  private let recording: any RecordingUseCase
  private let directory: any AuthoritativeDirectoryUseCase
  private var liveTranscriptTask: Task<Void, Never>?

  public init(
    recording: any RecordingUseCase,
    directory: any AuthoritativeDirectoryUseCase
  ) {
    self.recording = recording
    self.directory = directory
  }

  public var isSessionPresented: Bool {
    switch state {
    case .recording, .finishing, .finishFailed:
      return true
    case .idle, .starting, .completed, .startFailed:
      return false
    }
  }

  public func restore() async {
    guard state == .idle else {
      return
    }
    await restoreDirectory()
    do {
      guard let snapshot = try await recording.restore() else {
        return
      }
      switch snapshot.activity {
      case .recording:
        state = .recording(snapshot.session)
        observeLiveTranscript(for: snapshot.session.meetingID)
      case .finishing:
        state = .finishing(snapshot.session)
      }
    } catch let error as RecordingError {
      state = .startFailed(error)
    } catch {
      state = .startFailed(.statePersistenceFailed)
    }
  }

  public func start() async {
    guard !isSessionPresented, state != .starting else {
      return
    }
    guard await ensureDirectoryIsAuthorized() else {
      return
    }
    state = .starting
    do {
      let snapshot = try await recording.start()
      state = .recording(snapshot.session)
      observeLiveTranscript(for: snapshot.session.meetingID)
    } catch RecordingError.recordingConsentRequired {
      state = .idle
      isRecordingNoticePresented = true
    } catch RecordingError.authoritativeDirectoryUnavailable {
      directoryState = .recoveryRequired(.renewAccess)
      state = .startFailed(.authoritativeDirectoryUnavailable)
    } catch let error as RecordingError {
      state = .startFailed(error)
    } catch {
      state = .startFailed(.captureCouldNotStart)
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
    case .idle, .starting, .finishing, .completed, .startFailed:
      return
    }
    state = .finishing(session)

    do {
      state = .completed(try await recording.stop())
    } catch RecordingError.invalidRecordedAudio {
      state = .startFailed(.invalidRecordedAudio)
    } catch let error as RecordingError {
      state = .finishFailed(session, error)
    } catch {
      state = .finishFailed(session, .recordingWriteFailed)
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

  private func ensureDirectoryIsAuthorized() async -> Bool {
    switch directoryState {
    case .authorized:
      return true
    case .checking:
      await restoreDirectory()
      if case .authorized = directoryState {
        return true
      }
      return false
    case .recoveryRequired:
      return false
    }
  }

  private func recovery(for error: Error) -> AuthoritativeDirectoryRecovery {
    (error as? DirectoryAccessError)?.recovery ?? .tryAgain
  }
}
