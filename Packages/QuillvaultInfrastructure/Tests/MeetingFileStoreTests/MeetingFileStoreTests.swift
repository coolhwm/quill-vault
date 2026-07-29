import Domain
import Foundation
import Testing

@testable import MeetingFileStore

@Suite("Meeting file store")
struct MeetingFileStoreTests {
  @Test("Persists a selected directory and restores it after a cold start")
  func selectedDirectoryColdStart() async throws {
    let root = try TemporaryDirectory()
    let bookmarks = InMemoryBookmarkStore()
    let scopes = ScopeAccessSpy()
    let dependencies = MeetingFileStoreDependencies.testing(
      defaultDirectory: root.url.appending(path: "default"),
      bookmarkStore: bookmarks,
      scopeAccess: scopes
    )
    let firstStore = MeetingFileStore(dependencies: dependencies)

    let selected = try await firstStore.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    let restored = try await MeetingFileStore(dependencies: dependencies)
      .restoreSelectedDirectory()

    #expect(selected == restored)
    #expect(await bookmarks.savedBookmark != nil)
  }

  #if os(macOS)
    @Test("Foundation security-scoped bookmarks round-trip a real directory")
    func foundationBookmarkRoundTrip() throws {
      let root = try TemporaryDirectory()
      let codec = FoundationDirectoryBookmarkCodec()

      let bookmark = try codec.create(for: root.url)
      let restored = try codec.resolve(bookmark)

      #expect(
        restored.url.standardizedFileURL
          == root.url.standardizedFileURL
      )
      #expect(!restored.isStale)
    }
  #endif

  @Test("Starts and stops security-scoped access exactly once around a selected scan")
  func balancesSecurityScope() async throws {
    let fixture = try MeetingDirectoryFixture()
    let bookmarks = InMemoryBookmarkStore()
    let scopes = ScopeAccessSpy()
    let dependencies = MeetingFileStoreDependencies.testing(
      defaultDirectory: fixture.root,
      bookmarkStore: bookmarks,
      scopeAccess: scopes
    )
    let store = MeetingFileStore(dependencies: dependencies)
    let selected = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )
    let startsBeforeScan = await scopes.startCount
    let stopsBeforeScan = await scopes.stopCount

    _ = try await store.scan(selected)

    let startsAfterScan = await scopes.startCount
    let stopsAfterScan = await scopes.stopCount
    #expect(startsAfterScan == startsBeforeScan + 1)
    #expect(stopsAfterScan == stopsBeforeScan + 1)
    #expect(startsAfterScan == stopsAfterScan)
  }

  @Test("A stale selected bookmark fails without consulting the default directory")
  func staleBookmarkDoesNotFallBack() async {
    let bookmarks = InMemoryBookmarkStore(
      savedBookmark: Data("stale".utf8)
    )
    let defaults = DefaultDirectoryProviderSpy()
    let dependencies = MeetingFileStoreDependencies.testing(
      defaultDirectoryProvider: defaults,
      bookmarkStore: bookmarks,
      bookmarkCodec: StaleBookmarkCodec()
    )
    let store = MeetingFileStore(dependencies: dependencies)

    await #expect(throws: DirectoryAccessError.bookmarkStale) {
      _ = try await store.restoreSelectedDirectory()
    }
    #expect(await defaults.resolveCount == 0)
  }

  @Test("Coordinated scans preserve stable IDs, ignore candidates, and never modify assets")
  func coordinatedReadOnlyScan() async throws {
    let fixture = try MeetingDirectoryFixture()
    let before = try fixture.snapshot()
    let store = MeetingFileStore(
      dependencies: .testing(defaultDirectory: fixture.root)
    )
    let directory = try await store.resolveDefaultDirectory()

    let firstScan = try await store.scan(directory)
    let secondScan = try await store.scan(directory)

    #expect(firstScan.meetings.map(\.id) == [fixture.meetingID])
    #expect(secondScan.meetings.map(\.id) == [fixture.meetingID])
    #expect(firstScan.fingerprints.count == 2)
    #expect(firstScan.diagnostics.map(\.code).contains(.candidateIgnored))
    #expect(try fixture.snapshot() == before)
  }

  @Test("An iCloud placeholder is not indexed and reports a recoverable error")
  func iCloudPlaceholderStopsScan() async throws {
    let fixture = try MeetingDirectoryFixture()
    let status = UbiquitousStatusStub(unavailableFileName: "recording.m4a")
    let store = MeetingFileStore(
      dependencies: .testing(
        defaultDirectory: fixture.root,
        ubiquitousStatus: status
      )
    )
    let directory = try await store.resolveDefaultDirectory()

    await #expect(throws: DirectoryAccessError.itemNotDownloaded) {
      _ = try await store.scan(directory)
    }
  }

  @Test("An undownloaded meeting manifest requests an iCloud download")
  func iCloudManifestPlaceholderStopsScan() async throws {
    let fixture = try MeetingDirectoryFixture()
    let store = MeetingFileStore(
      dependencies: .testing(
        defaultDirectory: fixture.root,
        ubiquitousStatus: UbiquitousStatusStub(
          unavailableFileName: "meeting.json"
        )
      )
    )
    let directory = try await store.resolveDefaultDirectory()

    await #expect(throws: DirectoryAccessError.itemNotDownloaded) {
      _ = try await store.scan(directory)
    }
  }

  @Test("Root read permission errors preserve the reauthorization recovery")
  func rootPermissionErrorMapping() {
    let scanner = MeetingDirectoryScanner(
      ubiquitousStatus: AlwaysDownloadedItemStatusChecker()
    )

    #expect(
      scanner.rootReadError(for: CocoaError(.fileReadNoPermission))
        == .permissionDenied
    )
  }

  @Test("A moved selected directory reports reauthorization and balances scope")
  func movedSelectedDirectory() async throws {
    let root = try TemporaryDirectory()
    let scopes = ScopeAccessSpy()
    let store = MeetingFileStore(
      dependencies: .testing(
        defaultDirectory: root.url,
        scopeAccess: scopes
      )
    )
    let selected = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    try FileManager.default.removeItem(at: root.url)

    await #expect(throws: DirectoryAccessError.directoryMoved) {
      _ = try await store.scan(selected)
    }
    #expect(await scopes.startCount == 1)
    #expect(await scopes.stopCount == 1)
  }

  @Test("A cancelled scan exits before producing a replacement snapshot")
  func scanCancellation() async throws {
    let fixture = try MeetingDirectoryFixture()
    let store = MeetingFileStore(
      dependencies: .testing(defaultDirectory: fixture.root)
    )
    let directory = try await store.resolveDefaultDirectory()
    let task = Task {
      try await store.scan(directory)
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }
}

private struct MeetingDirectoryFixture {
  private let temporary: TemporaryDirectory
  let root: URL
  let meetingID = MeetingID(
    rawValue: UUID(uuidString: "51529D31-2205-4299-BECE-FA489FF9FA22")!
  )

  init() throws {
    let temporary = try TemporaryDirectory()
    self.temporary = temporary
    root = temporary.url

    let meeting = root.appending(path: "meeting-20260730-120000", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    let manifest = """
      {"schemaVersion":1,"meetingID":"\(meetingID.rawValue.uuidString)","createdAt":"2026-07-30T04:00:00Z"}
      """
    try Data(manifest.utf8).write(to: meeting.appending(path: "meeting.json"))
    try Data("audio".utf8).write(to: meeting.appending(path: "recording.m4a"))
    try Data("# Transcript".utf8).write(to: meeting.appending(path: "transcript.md"))

    let candidate = root.appending(
      path: "meeting-20260730-120000.candidate",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: candidate.appending(path: "minutes.md"))
  }

  func snapshot() throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil
    )
    var result: [String: Data] = [:]
    while let fileURL = enumerator?.nextObject() as? URL {
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
      if !isDirectory.boolValue {
        let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
        result[relative] = try Data(contentsOf: fileURL)
      }
    }
    return result
  }
}

private final class TemporaryDirectory: @unchecked Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "quillvault-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

private actor InMemoryBookmarkStore: DirectoryBookmarkStoring {
  private(set) var savedBookmark: Data?

  init(savedBookmark: Data? = nil) {
    self.savedBookmark = savedBookmark
  }

  func load() async -> Data? {
    savedBookmark
  }

  func save(_ data: Data) async throws {
    savedBookmark = data
  }
}

private actor ScopeAccessSpy: SecurityScopedResourceAccessing {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  func startAccessing(_ url: URL) async -> Bool {
    startCount += 1
    return true
  }

  func stopAccessing(_ url: URL) async {
    stopCount += 1
  }
}

private actor DefaultDirectoryProviderSpy: DefaultDirectoryProviding {
  private(set) var resolveCount = 0

  func resolve() async throws -> URL {
    resolveCount += 1
    throw DirectoryAccessError.iCloudUnavailable
  }
}

private struct StaleBookmarkCodec: DirectoryBookmarkCoding {
  func create(for url: URL) throws -> Data {
    Data()
  }

  func resolve(_ data: Data) throws -> ResolvedDirectoryBookmark {
    .init(url: URL(fileURLWithPath: "/stale"), isStale: true)
  }
}

private struct UbiquitousStatusStub: UbiquitousItemStatusChecking {
  let unavailableFileName: String

  func isDownloaded(_ url: URL) throws -> Bool {
    url.lastPathComponent != unavailableFileName
  }
}
