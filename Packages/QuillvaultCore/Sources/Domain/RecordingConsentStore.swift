public protocol RecordingConsentStore: Sendable {
  func hasAcknowledgedRecordingNotice() async -> Bool
  func acknowledgeRecordingNotice() async throws
}
