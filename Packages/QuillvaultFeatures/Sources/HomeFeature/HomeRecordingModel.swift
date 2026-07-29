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

@MainActor
@Observable
public final class HomeRecordingModel {
  public private(set) var state: HomeRecordingState = .idle
  public var isRecordingNoticePresented = false

  private let recording: any RecordingUseCase

  public init(recording: any RecordingUseCase) {
    self.recording = recording
  }

  public var isSessionPresented: Bool {
    switch state {
    case .recording, .finishing, .finishFailed:
      return true
    case .idle, .starting, .completed, .startFailed:
      return false
    }
  }

  public func start() async {
    guard !isSessionPresented, state != .starting else {
      return
    }
    state = .starting
    do {
      let snapshot = try await recording.start()
      state = .recording(snapshot.session)
    } catch RecordingError.recordingConsentRequired {
      state = .idle
      isRecordingNoticePresented = true
    } catch let error as RecordingError {
      state = .startFailed(error)
    } catch {
      state = .startFailed(.captureCouldNotStart)
    }
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
    state = .idle
  }
}
