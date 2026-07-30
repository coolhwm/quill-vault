import Domain
import Foundation
import Testing

@testable import AudioCapture
@testable import MeetingFileStore

@Suite("Recording adapter integration")
struct RecordingIntegrationTests {
  @Test("A recorder start failure leaves no authoritative meeting directory")
  func startFailureLeavesNoGhost() async throws {
    let root = try TemporaryDirectory()
    let files = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let engine = AudioCaptureEngine(
      files: files,
      permission: GrantedPermission(),
      makeRecorder: { FailingRecorder() },
      validator: InvalidValidator()
    )

    await #expect(throws: RecordingError.captureCouldNotStart) {
      _ = try await engine.start(.fixture())
    }

    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        .isEmpty
    )
  }

  @Test("Invalid audio remains recoverable but is not indexed as a meeting")
  func invalidAudioIsNotPublished() async throws {
    let root = try TemporaryDirectory()
    let files = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let directory = try #require(await files.restoreSelectedDirectory())
    let engine = AudioCaptureEngine(
      files: files,
      permission: GrantedPermission(),
      makeRecorder: { HeaderOnlyRecorder() },
      validator: InvalidValidator()
    )
    let session = RecordingSession.fixture()
    _ = try await engine.start(session)

    await #expect(throws: RecordingError.invalidRecordedAudio) {
      _ = try await engine.stop(meetingID: session.meetingID)
    }

    let scan = try await files.scan(directory)
    #expect(scan.meetings.isEmpty)
    let meetingDirectory = try #require(
      FileManager.default.contentsOfDirectory(
        at: root.url,
        includingPropertiesForKeys: nil
      ).first
    )
    #expect(
      FileManager.default.fileExists(
        atPath: meetingDirectory.appending(path: "recording.m4a").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: meetingDirectory.appending(path: "meeting.json").path
      )
    )
  }
}

private struct GrantedPermission: MicrophonePermissionAuthorizing {
  func requestPermission() async -> Bool {
    true
  }
}

private struct FailingRecorder: AudioRecorderDriving {
  func start(at url: URL) async throws -> Date {
    throw RecordingError.captureCouldNotStart
  }

  func stop() {}
}

private struct HeaderOnlyRecorder: AudioRecorderDriving {
  func start(at url: URL) async throws -> Date {
    try Data("header".utf8).write(to: url)
    return Date(timeIntervalSince1970: 1_722_470_400)
  }

  func stop() {}
}

private struct InvalidValidator: RecordedAudioValidating {
  func validate(_ url: URL) throws -> RecordedAudio {
    RecordedAudio(durationSeconds: 0, packetCount: 0, byteCount: 6)
  }
}

private final class TemporaryDirectory: @unchecked Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

extension RecordingSession {
  fileprivate static func fixture() -> Self {
    .init(
      meetingID: MeetingID(rawValue: UUID()),
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}
