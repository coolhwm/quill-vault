public protocol RecordingSessionStore: Sendable {
  func activeSession() async throws -> RecordingSession?
  func saveActive(_ session: RecordingSession) async throws
  func finish(
    _ session: RecordingSession,
    audio: RecordedAudio
  ) async throws
  func abandon(_ session: RecordingSession) async throws
}
