public enum RecordingError: Error, Equatable, Sendable {
  case alreadyRecording
  case recordingConsentRequired
  case microphonePermissionDenied
  case insufficientStorage
  case authoritativeDirectoryUnavailable
  case captureCouldNotStart
  case recordingWriteFailed
  case invalidRecordedAudio
  case statePersistenceFailed
  case noActiveRecording
}
