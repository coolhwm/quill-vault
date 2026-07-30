import Domain
import Foundation

protocol MicrophonePermissionAuthorizing: Sendable {
  func requestPermission() async -> Bool
}

protocol AudioRecorderDriving: Sendable {
  func start(at url: URL) async throws -> Date
  func frames() -> AsyncStream<AudioFrame>
  func stop()
}

extension AudioRecorderDriving {
  func frames() -> AsyncStream<AudioFrame> {
    AsyncStream { $0.finish() }
  }
}

protocol RecordedAudioValidating: Sendable {
  func validate(_ url: URL) throws -> RecordedAudio
}
