public enum RecordingError: Error, Equatable, Sendable {
  case alreadyRecording
  case recordingConsentRequired
  case microphonePermissionDenied
  case insufficientStorage
  case authoritativeDirectoryUnavailable
  case captureCouldNotStart
  case recordingWriteFailed
  case invalidRecordedAudio
  case transcriptionFailed
  case unsupportedTranscriptionLocale
  case speechAssetsUnavailable
  case transcriptPublicationFailed
  case statePersistenceFailed
  case noActiveRecording
}
