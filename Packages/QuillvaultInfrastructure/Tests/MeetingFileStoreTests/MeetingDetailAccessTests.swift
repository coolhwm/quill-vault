import Domain
import Foundation
import Testing

@testable import MeetingFileStore

@Suite("Meeting detail access")
struct MeetingDetailAccessTests {
  @Test("A missing recording does not hide a readable transcript")
  func independentAssetFailures() async throws {
    let fixture = try MeetingDetailDirectoryFixture()
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try await store.authorizeSelectedDirectory(
      AuthoritativeDirectorySelection(
        opaqueReference: fixture.root.absoluteString
      )
    )

    let detail = try await store.loadMeetingDetail(
      in: directory,
      meeting: fixture.entry
    )

    guard case .available(let timeline) = detail.transcript else {
      Issue.record("Expected the transcript to remain readable")
      return
    }
    #expect(timeline.segments.map(\.text) == ["第一段", "Second segment"])
    #expect(detail.recording == .missing)
    #expect(detail.minutes == .missing)
  }

  @Test("An iCloud-only recording degrades only the player asset")
  func recordingDownloadRequiredIsLocal() async throws {
    let fixture = try MeetingDetailDirectoryFixture(includeRecording: true)
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        ubiquitousStatus: RecordingNeedsDownloadStatus()
      )
    )
    let directory = try await store.authorizeSelectedDirectory(
      AuthoritativeDirectorySelection(
        opaqueReference: fixture.root.absoluteString
      )
    )

    let detail = try await store.loadMeetingDetail(
      in: directory,
      meeting: fixture.entry
    )

    guard case .available = detail.transcript else {
      Issue.record("Expected transcript availability")
      return
    }
    #expect(detail.recording == .downloadRequired)
  }

  @Test("An unreadable recording does not hide the text record")
  func unreadableRecordingIsLocal() async throws {
    let fixture = try MeetingDetailDirectoryFixture(includeRecording: true)
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try await store.authorizeSelectedDirectory(
      AuthoritativeDirectorySelection(
        opaqueReference: fixture.root.absoluteString
      )
    )

    let detail = try await store.loadMeetingDetail(
      in: directory,
      meeting: fixture.entry
    )

    guard case .available = detail.transcript else {
      Issue.record("Expected transcript availability")
      return
    }
    #expect(detail.recording == .unreadable)
  }

  @Test("Playback access keeps security scope balanced behind an opaque source")
  func playbackAccessBalancesScope() async throws {
    let fixture = try MeetingDetailDirectoryFixture(includeRecording: true)
    defer { fixture.remove() }
    let scopes = PlaybackScopeSpy()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        scopeAccess: scopes
      )
    )
    let directory = try await store.authorizeSelectedDirectory(
      AuthoritativeDirectorySelection(
        opaqueReference: fixture.root.absoluteString
      )
    )
    let startsBefore = await scopes.startCount
    let stopsBefore = await scopes.stopCount
    let sourceID = MeetingAudioSourceID(
      rawValue: "\(directory.id.rawValue)\n\(fixture.entry.relativeDirectory)"
    )

    let url = try await store.beginAudioPlayback(sourceID: sourceID)
    #expect(url.lastPathComponent == "recording.m4a")
    await store.endAudioPlayback(sourceID: sourceID)

    #expect(await scopes.startCount == startsBefore + 1)
    #expect(await scopes.stopCount == stopsBefore + 1)
  }
}

private actor PlaybackScopeSpy: SecurityScopedResourceAccessing {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  func startAccessing(_ url: URL) -> Bool {
    startCount += 1
    return true
  }

  func stopAccessing(_ url: URL) {
    stopCount += 1
  }
}

private struct RecordingNeedsDownloadStatus:
  UbiquitousItemStatusChecking
{
  func isDownloaded(_ url: URL) -> Bool {
    url.lastPathComponent != "recording.m4a"
  }
}

private struct MeetingDetailDirectoryFixture {
  let root: URL
  let meetingURL: URL
  let entry: MeetingIndexEntry

  init(includeRecording: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "meeting-detail-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    meetingURL = root.appending(
      path: "meeting-20270115-080000",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: meetingURL,
      withIntermediateDirectories: true
    )
    let id = MeetingID(
      rawValue: UUID(uuidString: "8AB93104-B4D2-4425-8E91-30CD1E2599BE")!
    )
    let manifest = MeetingManifest(
      meetingID: id.rawValue,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try JSONEncoder().encode(manifest).write(
      to: meetingURL.appending(path: "meeting.json")
    )
    let transcript = [
      "---",
      "audioDurationSeconds: 20.0",
      "---",
      "",
      "# 文字记录",
      "",
      "- [000.0–010.0] 第一段",
      "- [010.0–020.0] Second segment",
    ].joined(separator: "\n")
    try transcript.write(
      to: meetingURL.appending(path: "transcript.md"),
      atomically: true,
      encoding: .utf8
    )
    if includeRecording {
      try Data([0]).write(to: meetingURL.appending(path: "recording.m4a"))
    }
    entry = MeetingIndexEntry(
      id: id,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: meetingURL.lastPathComponent,
      assets: includeRecording
        ? [.recording, .transcript]
        : [.transcript],
      durationSeconds: 20
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
