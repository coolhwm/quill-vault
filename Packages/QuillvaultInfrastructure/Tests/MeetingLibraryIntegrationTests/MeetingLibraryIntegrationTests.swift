import Application
import Domain
import Foundation
import PersistenceGRDB
import Testing

@testable import MeetingFileStore

@Suite("Meeting library reconstruction")
struct MeetingLibraryIntegrationTests {
  @Test("Deleting the index reconstructs stable IDs without changing authoritative files")
  func rebuildAfterIndexDeletion() async throws {
    let fixture = try IntegrationFixture()
    let originalFiles = try fixture.fileSnapshot()
    let bookmarks = IntegrationBookmarkStore()
    let fileStore = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        bookmarkStore: bookmarks
      )
    )
    let firstCatalog = try GRDBMeetingCatalog.openRecovering(at: fixture.databaseURL)
    let firstWorkflow = MeetingLibraryWorkflow(
      directoryAccess: fileStore,
      catalog: firstCatalog
    )

    let selected = try await firstWorkflow.select(
      AuthoritativeDirectorySelection(
        opaqueReference: fixture.root.absoluteString
      )
    )
    try await firstCatalog.close()
    try FileManager.default.removeItem(at: fixture.databaseURL)

    let restoredFileStore = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        bookmarkStore: bookmarks
      )
    )
    let rebuiltCatalog = try GRDBMeetingCatalog.openRecovering(at: fixture.databaseURL)
    let rebuilt = try await MeetingLibraryWorkflow(
      directoryAccess: restoredFileStore,
      catalog: rebuiltCatalog
    ).restore()

    #expect(selected.meetings.map(\.id) == [fixture.meetingID])
    #expect(rebuilt.meetings.map(\.id) == [fixture.meetingID])
    #expect(try fixture.fileSnapshot() == originalFiles)
  }

  @Test("A corrupt index is quarantined and rebuilt from unchanged meeting files")
  func rebuildAfterIndexCorruption() async throws {
    let fixture = try IntegrationFixture()
    let originalFiles = try fixture.fileSnapshot()
    let bookmarks = IntegrationBookmarkStore()
    let firstFileStore = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        bookmarkStore: bookmarks
      )
    )
    let firstCatalog = try GRDBMeetingCatalog.openRecovering(
      at: fixture.databaseURL
    )
    _ = try await MeetingLibraryWorkflow(
      directoryAccess: firstFileStore,
      catalog: firstCatalog
    ).select(
      AuthoritativeDirectorySelection(
        opaqueReference: fixture.root.absoluteString
      )
    )
    try await firstCatalog.close()
    try Data("not sqlite".utf8).write(to: fixture.databaseURL)

    let rebuiltCatalog = try GRDBMeetingCatalog.openRecovering(
      at: fixture.databaseURL
    )
    let rebuilt = try await MeetingLibraryWorkflow(
      directoryAccess: MeetingFileStore(
        dependencies: .testing(
          authorizedDirectory: fixture.root,
          bookmarkStore: bookmarks
        )
      ),
      catalog: rebuiltCatalog
    ).restore()

    #expect(rebuilt.meetings.map(\.id) == [fixture.meetingID])
    #expect(try fixture.fileSnapshot() == originalFiles)
  }
}

private final class IntegrationFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  private let meetingURL: URL
  let meetingID = MeetingID(
    rawValue: UUID(uuidString: "8CB77B23-F415-429A-A406-B3D6EBB51131")!
  )

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "quillvault-integration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    databaseURL = root.appending(path: ".index/catalog.sqlite")
    meetingURL = root.appending(
      path: "meeting-20260730-140000",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: meetingURL,
      withIntermediateDirectories: true
    )
    let manifest = """
      {"schemaVersion":1,"meetingID":"\(meetingID.rawValue.uuidString)","createdAt":"2026-07-30T06:00:00Z"}
      """
    try Data(manifest.utf8).write(to: meetingURL.appending(path: "meeting.json"))
    try Data("audio".utf8).write(to: meetingURL.appending(path: "recording.m4a"))
    try Data("# Transcript".utf8).write(to: meetingURL.appending(path: "transcript.md"))
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func fileSnapshot() throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
      at: meetingURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    var files: [String: Data] = [:]
    while let url = enumerator?.nextObject() as? URL {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory != true {
        let relative = url.path.replacingOccurrences(
          of: meetingURL.path + "/",
          with: ""
        )
        files[relative] = try Data(contentsOf: url)
      }
    }
    return files
  }
}

private actor IntegrationBookmarkStore: DirectoryBookmarkStoring {
  private var bookmark: Data?

  func load() async -> Data? {
    bookmark
  }

  func save(_ data: Data) async throws {
    bookmark = data
  }
}
