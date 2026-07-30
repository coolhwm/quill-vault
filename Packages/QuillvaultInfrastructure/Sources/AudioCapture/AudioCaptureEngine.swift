import Domain
import Foundation

public actor AudioCaptureEngine: AudioCapture {
  typealias RecorderFactory = @Sendable () -> any AudioRecorderDriving

  private struct ActiveCapture {
    let session: RecordingSession
    let reservation: RecordingFileReservation
    let recorder: any AudioRecorderDriving
    var hasStopped: Bool
  }

  private let files: any RecordingFileStore
  private let permission: any MicrophonePermissionAuthorizing
  private let makeRecorder: RecorderFactory
  private let validator: any RecordedAudioValidating
  private var startingMeetingID: MeetingID?
  private var activeCapture: ActiveCapture?
  private var completedRecordings: [MeetingID: RecordedAudio] = [:]

  public init(fileStore: any RecordingFileStore) {
    files = fileStore
    permission = SystemMicrophonePermissionAuthorizer()
    makeRecorder = { AVAudioEngineRecorderDriver() }
    validator = AVRecordedAudioValidator()
  }

  init(
    files: any RecordingFileStore,
    permission: any MicrophonePermissionAuthorizing,
    makeRecorder: @escaping RecorderFactory,
    validator: any RecordedAudioValidating
  ) {
    self.files = files
    self.permission = permission
    self.makeRecorder = makeRecorder
    self.validator = validator
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
        recorder: recorder,
        hasStopped: false
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
    }

    let audio: RecordedAudio
    do {
      audio = try validator.validate(active.reservation.recordingURL)
    } catch {
      await files.abandonRecording(meetingID: meetingID)
      activeCapture = nil
      throw map(error, fallback: .invalidRecordedAudio)
    }
    guard audio.isValid else {
      await files.abandonRecording(meetingID: meetingID)
      activeCapture = nil
      throw RecordingError.invalidRecordedAudio
    }

    do {
      try await files.finishRecording(meetingID: meetingID)
    } catch {
      throw map(error, fallback: .recordingWriteFailed)
    }
    activeCapture = nil
    completedRecordings[meetingID] = audio
    return audio
  }

  public func recoverInterrupted(
    _ session: RecordingSession
  ) async throws -> RecordedAudio? {
    guard
      let reservation = try await files.recoverInterruptedRecording(for: session)
    else {
      return nil
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
      await files.abandonRecording(meetingID: session.meetingID)
      throw map(error, fallback: .recordingWriteFailed)
    }
    guard audio.isValid else {
      await files.abandonRecording(meetingID: session.meetingID)
      return nil
    }

    do {
      try await files.finishRecording(meetingID: session.meetingID)
      completedRecordings[session.meetingID] = audio
      return audio
    } catch is CancellationError {
      await files.abandonRecording(meetingID: session.meetingID)
      throw CancellationError()
    } catch {
      await files.abandonRecording(meetingID: session.meetingID)
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

  public func cancel(meetingID: MeetingID) async {
    guard
      let active = activeCapture,
      active.session.meetingID == meetingID
    else {
      await files.cancelRecording(meetingID: meetingID)
      return
    }
    active.recorder.stop()
    activeCapture = nil
    completedRecordings[meetingID] = nil
    await files.cancelRecording(meetingID: meetingID)
  }

  private func map(
    _ error: any Error,
    fallback: RecordingError
  ) -> RecordingError {
    return error as? RecordingError ?? fallback
  }
}
