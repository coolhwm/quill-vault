import Domain
import Foundation
import Testing

@testable import MeetingFileStore

@Suite("Transcript file publication")
struct FileTranscriptPublisherTests {
  @Test("Final log is flushed and transcript is atomically readable")
  func publishesAndReadsBack() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let publisher = FileTranscriptPublisher()
    let segment = TranscriptSegmentCandidate(
      startSeconds: 0.25,
      endSeconds: 1.75,
      text: "测试文字记录"
    )
    try await publisher.appendFinal(
      segment,
      meetingID: fixture.meetingID,
      recordingURL: fixture.recordingURL
    )
    let revision = try makeRevision(
      meetingID: fixture.meetingID,
      candidates: [segment],
      duration: 2
    )

    let readback = try await publisher.publish(
      revision,
      recordingURL: fixture.recordingURL
    )

    #expect(readback == revision)
    let markdown = try String(
      contentsOf: fixture.directoryURL.appending(path: "transcript.md"),
      encoding: .utf8
    )
    #expect(markdown.contains("revisionID: \(revision.id)"))
    #expect(markdown.contains("0.250–1.750 秒  测试文字记录"))
    let log = try String(
      contentsOf: fixture.directoryURL.appending(path: ".transcript-final.jsonl"),
      encoding: .utf8
    )
    #expect(log.hasSuffix("\n"))
    #expect(log.contains("测试文字记录"))
  }

  @Test("Replacement failure preserves the previous published transcript")
  func replacementFailurePreservesExistingFile() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let transcriptURL = fixture.directoryURL.appending(path: "transcript.md")
    try Data("previous".utf8).write(to: transcriptURL)
    let publisher = FileTranscriptPublisher { _, _ in
      throw TestFailure()
    }
    let revision = try makeRevision(
      meetingID: fixture.meetingID,
      candidates: [
        TranscriptSegmentCandidate(startSeconds: 0, endSeconds: 1, text: "new")
      ],
      duration: 1
    )

    await #expect(throws: TranscriptError.publicationFailed) {
      _ = try await publisher.publish(
        revision,
        recordingURL: fixture.recordingURL
      )
    }

    #expect(try Data(contentsOf: transcriptURL) == Data("previous".utf8))
    let temporaryFiles = try FileManager.default.contentsOfDirectory(
      at: fixture.directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "tmp" }
    #expect(temporaryFiles.isEmpty)
  }

  @Test("A mismatched meeting manifest cannot receive a transcript")
  func rejectsMismatchedManifest() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let otherID = MeetingID(rawValue: UUID())
    let revision = try makeRevision(
      meetingID: otherID,
      candidates: [],
      duration: 1
    )

    await #expect(throws: TranscriptError.publicationFailed) {
      _ = try await FileTranscriptPublisher().publish(
        revision,
        recordingURL: fixture.recordingURL
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directoryURL.appending(path: "transcript.md").path
      )
    )
  }

  private func makeRevision(
    meetingID: MeetingID,
    candidates: [TranscriptSegmentCandidate],
    duration: Double
  ) throws -> TranscriptRevision {
    TranscriptRevision(
      meetingID: meetingID,
      localeIdentifier: "zh-CN",
      timeline: try TranscriptTimeline.normalizing(
        candidates,
        audioDurationSeconds: duration
      )
    )
  }
}

private struct TestFailure: Error {}

private struct Fixture {
  let rootURL: URL
  let directoryURL: URL
  let recordingURL: URL
  let meetingID: MeetingID

  init() throws {
    meetingID = MeetingID(rawValue: UUID())
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "transcript-publisher-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    directoryURL = rootURL.appending(
      path: "meeting-\(meetingID.rawValue.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    recordingURL = directoryURL.appending(path: "recording.m4a")
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
    let manifest = MeetingManifest(
      meetingID: meetingID.rawValue,
      createdAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(
      to: directoryURL.appending(path: "meeting.json")
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
