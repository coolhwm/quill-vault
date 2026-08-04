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
      expectedTranscriptFingerprint: source.revision.contentFingerprint,
      expectedExistingMinutesFingerprint: nil
    )

    #expect(
      try String(
        contentsOf: fixture.meetingURL.appending(path: "minutes.md"),
        encoding: .utf8
      ) == markdown
    )
    let snapshot = try await store.loadMinutesSnapshot(
      in: directory,
      meeting: fixture.entry
    )
    #expect(snapshot?.contentFingerprint == GenerationInputFingerprint.make(markdown))
    #expect(snapshot?.transcriptRevisionID == source.revision.id)
    #expect(snapshot?.transcriptFingerprint == source.revision.contentFingerprint)
    let starts = await scopes.startCount
    let stops = await scopes.stopCount
    #expect(starts == stops)
    #expect(starts == 4)
  }

  @Test("An external minutes edit wins the atomic replacement race")
  func preservesExternalMinutesDuringAtomicReplacement() async throws {
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
    let originalMarkdown = """
      ---
      schemaVersion: 1
      generationJobID: (UUID().uuidString)
      generationNumber: 1
      transcriptRevisionID: (source.revision.id)
      transcriptFingerprint: (source.revision.contentFingerprint)
      model: test-model
      informationMayBeIncomplete: false
      ---

      # 结构化纪要

      初始版本。
      """
    try await store.publishMinutes(
      originalMarkdown,
      in: directory,
      meeting: fixture.entry,
      expectedTranscriptRevisionID: source.revision.id,
      expectedTranscriptFingerprint: source.revision.contentFingerprint,
      expectedExistingMinutesFingerprint: nil
    )
    let originalSnapshot = try await store.loadMinutesSnapshot(
      in: directory,
      meeting: fixture.entry
    )
    let externalMarkdown = "# 用户手工修改的纪要\n\n保留这份版本。"
    try externalMarkdown.write(
      to: fixture.meetingURL.appending(path: "minutes.md"),
      atomically: true,
      encoding: .utf8
    )

    await #expect(throws: GenerationFileError.externalMinutesChanged) {
      try await store.publishMinutes(
        "# 模型候选版本\n\n不应覆盖外部修改。",
        in: directory,
        meeting: fixture.entry,
        expectedTranscriptRevisionID: source.revision.id,
        expectedTranscriptFingerprint: source.revision.contentFingerprint,
        expectedExistingMinutesFingerprint: originalSnapshot?.contentFingerprint
      )
    }
    #expect(
      try String(
        contentsOf: fixture.meetingURL.appending(path: "minutes.md"),
        encoding: .utf8
      ) == externalMarkdown
    )
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
        expectedTranscriptFingerprint: source.revision.contentFingerprint,
        expectedExistingMinutesFingerprint: nil
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.meetingURL.appending(path: "minutes.md").path
      )
    )
  }

  @Test("Publishes minutes when generation pins optimized transcript that differs from original")
  func publishesUsingOptimizedTranscriptWhenPresent() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )

    // Original stays as fixture wrote; optimized has different segment text.
    try """
    ---
    schemaVersion: 1
    revisionID: optimized-fixture
    contentFingerprint: placeholder
    locale: zh-CN
    audioDurationSeconds: 20.000
    transcriptVersion: optimized
    parentVersion: original
    qualityStrategyID: offline-readability
    qualityStrategyVersion: v1
    ---

    # 优化文字记录

    - [000.0–010.0] 优化后的第一段
    - [010.0–020.0] 优化后的第二段
    """.write(
      to: fixture.meetingURL.appending(path: "transcript.optimized.md"),
      atomically: true,
      encoding: .utf8
    )

    let originalMarkdown = try String(
      contentsOf: fixture.meetingURL.appending(path: "transcript.md"),
      encoding: .utf8
    )
    let optimizedMarkdown = try String(
      contentsOf: fixture.meetingURL.appending(path: "transcript.optimized.md"),
      encoding: .utf8
    )
    #expect(originalMarkdown != optimizedMarkdown)

    let source = try await store.loadTranscript(
      in: directory,
      meeting: fixture.entry
    )
    // Preferred source must be optimized text, not original.
    #expect(
      source.revision.timeline.segments.map(\.text) == [
        "优化后的第一段",
        "优化后的第二段",
      ])

    let originalTimeline = try MeetingTranscriptMarkdownParser().parse(
      originalMarkdown
    )
    let originalOnly = TranscriptRevision(
      meetingID: fixture.entry.id,
      localeIdentifier: "zh-CN",
      timeline: originalTimeline
    )
    #expect(source.revision.contentFingerprint != originalOnly.contentFingerprint)
    #expect(source.revision.id != originalOnly.id)

    let minutes = """
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

      基于优化文字记录生成。
      """

    try await store.publishMinutes(
      minutes,
      in: directory,
      meeting: fixture.entry,
      expectedTranscriptRevisionID: source.revision.id,
      expectedTranscriptFingerprint: source.revision.contentFingerprint,
      expectedExistingMinutesFingerprint: nil
    )

    #expect(
      try String(
        contentsOf: fixture.meetingURL.appending(path: "minutes.md"),
        encoding: .utf8
      ) == minutes
    )
    // Original asset must remain untouched after successful publish.
    #expect(
      try String(
        contentsOf: fixture.meetingURL.appending(path: "transcript.md"),
        encoding: .utf8
      ) == originalMarkdown
    )
    let snapshot = try await store.loadMinutesSnapshot(
      in: directory,
      meeting: fixture.entry
    )
    #expect(snapshot?.transcriptRevisionID == source.revision.id)
    #expect(snapshot?.transcriptFingerprint == source.revision.contentFingerprint)
  }

  @Test("Rejects publish when preferred optimized transcript changes after load")
  func rejectsChangedOptimizedTranscript() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.remove() }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )
    try """
    ---
    audioDurationSeconds: 20.0
    locale: zh-CN
    ---

    # 优化文字记录

    - [000.0–010.0] 优化第一段
    - [010.0–020.0] 优化第二段
    """.write(
      to: fixture.meetingURL.appending(path: "transcript.optimized.md"),
      atomically: true,
      encoding: .utf8
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

    # 优化文字记录

    - [000.0–010.0] 优化被外部改写
    - [010.0–020.0] 优化第二段
    """.write(
      to: fixture.meetingURL.appending(path: "transcript.optimized.md"),
      atomically: true,
      encoding: .utf8
    )

    await #expect(throws: GenerationFileError.sourceChanged) {
      try await store.publishMinutes(
        "# 结构化纪要\n\n不应发布。",
        in: directory,
        meeting: fixture.entry,
        expectedTranscriptRevisionID: source.revision.id,
        expectedTranscriptFingerprint: source.revision.contentFingerprint,
        expectedExistingMinutesFingerprint: nil
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
        expectedTranscriptFingerprint: source.revision.contentFingerprint,
        expectedExistingMinutesFingerprint: nil
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
