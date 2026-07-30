import Application
import Domain
import Foundation
import MeetingFileStore
import PersistenceGRDB
import Testing

@Suite("Transcription adapter integration")
struct TranscriptionIntegrationTests {
  @Test("File catch-up publishes transcript and commits durable recovery state")
  func catchUpPublishesAtomically() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let jobs = try GRDBTranscriptionJobStore.open(at: fixture.databaseURL)
    let workflow = TranscriptionWorkflow(
      engine: IntegrationSpeechEngine(),
      publisher: FileTranscriptPublisher(),
      jobs: jobs
    )

    let revision = try await workflow.finalize(
      fixture.completion,
      localeIdentifier: "zh-CN"
    )

    #expect(revision.timeline.segments.map(\.text) == ["第一段", "第二段"])
    #expect(try await jobs.pendingJobs().isEmpty)
    let transcript = try String(
      contentsOf: fixture.directoryURL.appending(path: "transcript.md"),
      encoding: .utf8
    )
    #expect(transcript.contains(revision.id))
    #expect(transcript.contains("第一段"))
    #expect(transcript.contains("第二段"))
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.directoryURL.appending(
          path: ".transcript-final.jsonl"
        ).path
      )
    )
  }
}

private struct IntegrationSpeechEngine: SpeechTranscriptionEngine {
  func liveResults(
    frames: AsyncStream<AudioFrame>,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    AsyncThrowingStream { $0.finish() }
  }

  func fileResults(
    at recordingURL: URL,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    AsyncThrowingStream { continuation in
      continuation.yield(
        SpeechRecognitionEvent(
          segment: TranscriptSegmentCandidate(
            startSeconds: 3,
            endSeconds: 6,
            text: "第二段"
          ),
          stability: .final
        )
      )
      continuation.yield(
        SpeechRecognitionEvent(
          segment: TranscriptSegmentCandidate(
            startSeconds: 0,
            endSeconds: 4,
            text: "第一段"
          ),
          stability: .final
        )
      )
      continuation.finish()
    }
  }
}

private struct Fixture {
  let rootURL: URL
  let directoryURL: URL
  let recordingURL: URL
  let databaseURL: URL
  let meetingID: MeetingID

  init() throws {
    meetingID = MeetingID(rawValue: UUID())
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "transcription-integration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    directoryURL = rootURL.appending(
      path: "meeting-\(meetingID.rawValue.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    recordingURL = directoryURL.appending(path: "recording.m4a")
    databaseURL = rootURL.appending(path: "transcription-state.sqlite")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    #expect(
      FileManager.default.createFile(
        atPath: recordingURL.path,
        contents: Data([1, 2, 3])
      )
    )
    let manifest: [String: Any] = [
      "schemaVersion": 1,
      "meetingID": meetingID.rawValue.uuidString,
      "createdAt": "2024-08-01T00:00:00Z",
    ]
    try JSONSerialization.data(
      withJSONObject: manifest,
      options: [.sortedKeys]
    ).write(to: directoryURL.appending(path: "meeting.json"))
  }

  var completion: RecordingCompletion {
    RecordingCompletion(
      session: RecordingSession(
        meetingID: meetingID,
        startedAt: Date(timeIntervalSince1970: 1_722_470_400)
      ),
      audio: RecordedAudio(
        durationSeconds: 6,
        packetCount: 100,
        byteCount: 1_000,
        fileURL: recordingURL
      )
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
