import Domain
import Foundation
import Testing

@testable import MeetingFileStore

@Suite("Generation file access")
struct GenerationFileStoreTests {
  @Test("Loads a transcript and publishes minutes with coordinated read-back")
  func loadsAndPublishesMinutes() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.remove() }
    let scopes = GenerationScopeSpy()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        scopeAccess: scopes
      )
    )
    let directory = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )

    let source = try await store.loadTranscript(
      in: directory,
      meeting: fixture.entry
    )
    let markdown = """
      ---
      schemaVersion: 1
      generationJobID: \(UUID().uuidString)
      generationNumber: 1
      transcriptRevisionID: \(source.revision.id)
      transcriptFingerprint: \(source.revision.contentFingerprint)
      model: test-model
      informationMayBeIncomplete: false
      ---

      # 结构化纪要

      # 会议结论

      已确认下一步。
      """

    try await store.publishMinutes(
      markdown,
      in: directory,
      meeting: fixture.entry,
      expectedTranscriptRevisionID: source.revision.id,
      expectedTranscriptFingerprint: source.revision.contentFingerprint
    )

    #expect(
      try String(
        contentsOf: fixture.meetingURL.appending(path: "minutes.md"),
        encoding: .utf8
      ) == markdown
    )
    let starts = await scopes.startCount
    let stops = await scopes.stopCount
    #expect(starts == stops)
    #expect(starts == 3)
  }

  @Test("A changed transcript is rejected before minutes publication")
  func rejectsChangedTranscript() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )
    let source = try await store.loadTranscript(
      in: directory,
      meeting: fixture.entry
    )
    try """
    ---
    audioDurationSeconds: 20.0
    locale: zh-CN
    ---

    # 文字记录

    - [000.0–010.0] 外部编辑后的文字
    - [010.0–020.0] 第二段
    """.write(
      to: fixture.meetingURL.appending(path: "transcript.md"),
      atomically: true,
      encoding: .utf8
    )

    await #expect(throws: GenerationFileError.sourceChanged) {
      try await store.publishMinutes(
        "# 结构化纪要\n\n不应发布。",
        in: directory,
        meeting: fixture.entry,
        expectedTranscriptRevisionID: source.revision.id,
        expectedTranscriptFingerprint: source.revision.contentFingerprint
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.meetingURL.appending(path: "minutes.md").path
      )
    )
  }

  @Test("A transcript revision metadata change is rejected even when content is unchanged")
  func rejectsChangedTranscriptRevisionMetadata() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )
    let source = try await store.loadTranscript(
      in: directory,
      meeting: fixture.entry
    )
    try """
    ---
    audioDurationSeconds: 20.0
    locale: en-US
    ---

    # 文字记录

    - [000.0–010.0] 第一段
    - [010.0–020.0] 第二段
    """.write(
      to: fixture.meetingURL.appending(path: "transcript.md"),
      atomically: true,
      encoding: .utf8
    )

    await #expect(throws: GenerationFileError.sourceChanged) {
      try await store.publishMinutes(
        "# 结构化纪要\n\n不应发布。",
        in: directory,
        meeting: fixture.entry,
        expectedTranscriptRevisionID: source.revision.id,
        expectedTranscriptFingerprint: source.revision.contentFingerprint
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.meetingURL.appending(path: "minutes.md").path
      )
    )
  }
}

private actor GenerationScopeSpy: SecurityScopedResourceAccessing {
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

private struct GenerationFixture {
  let root: URL
  let meetingURL: URL
  let entry: MeetingIndexEntry

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "generation-file-\(UUID().uuidString)",
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
    let id = MeetingID(rawValue: UUID())
    let manifest = MeetingManifest(
      meetingID: id.rawValue,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try JSONEncoder().encode(manifest).write(
      to: meetingURL.appending(path: "meeting.json")
    )
    try """
    ---
    audioDurationSeconds: 20.0
    locale: zh-CN
    ---

    # 文字记录

    - [000.0–010.0] 第一段
    - [010.0–020.0] 第二段
    """.write(
      to: meetingURL.appending(path: "transcript.md"),
      atomically: true,
      encoding: .utf8
    )
    entry = MeetingIndexEntry(
      id: id,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      relativeDirectory: meetingURL.lastPathComponent,
      assets: [.transcript],
      durationSeconds: 20
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
