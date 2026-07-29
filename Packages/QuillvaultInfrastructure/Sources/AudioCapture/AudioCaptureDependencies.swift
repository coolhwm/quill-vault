import Domain
import Foundation

protocol MicrophonePermissionAuthorizing: Sendable {
  func requestPermission() async -> Bool
}

protocol AudioRecorderDriving: Sendable {
  func start(at url: URL) async throws -> Date
  func stop()
}

protocol RecordedAudioValidating: Sendable {
  func validate(_ url: URL) throws -> RecordedAudio
}
