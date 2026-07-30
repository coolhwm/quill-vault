import Application
import Domain
import Foundation
import Testing

@testable import MeetingsFeature

@MainActor
@Suite("Meetings model")
struct MeetingsModelTests {
  @Test("Loads the cold-start library snapshot")
  func loadsSnapshot() async {
    let snapshot = MeetingLibrarySnapshot.fixture
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(restoreResult: .success(snapshot))
    )

    await model.load()

    #expect(model.state == .loaded(snapshot))
  }

  @Test(
    "Maps a stale bookmark to explicit reauthorization instead of another directory"
  )
  func staleBookmarkRecovery() async {
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkStale)
      )
    )

    await model.load()

    #expect(model.state == .failed(.renewAccess))
  }

  @Test("Maps a missing bookmark to initial directory selection")
  func missingBookmarkRecovery() async {
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkMissing)
      )
    )

    await model.load()

    #expect(model.state == .failed(.chooseDirectory))
  }

  @Test("Maps an unavailable iCloud item to a download recovery")
  func iCloudDownloadRecovery() async {
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.itemNotDownloaded)
      )
    )

    await model.load()

    #expect(model.state == .failed(.downloadRequired))
  }

  @Test("A recording-only meeting can retry its durable transcript job")
  func retryPendingTranscript() async {
    let recovery = TranscriptionRecoveryUseCaseStub()
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .success(.fixture)
      ),
      transcriptionRecovery: recovery
    )
    let meetingID = MeetingID(
      rawValue: UUID(uuidString: "5C46C983-86A7-4D39-B70D-0F42C917470C")!
    )

    await model.retryTranscript(meetingID: meetingID)

    #expect(await recovery.callCount == 1)
    #expect(model.recoveringMeetingID == nil)
    #expect(model.state == .loaded(.fixture))
  }

  @Test("Combines text, date, status, and model filters at the use-case boundary")
  func combinedSearch() async {
    let recorder = SearchQueryRecorder()
    let result = MeetingIndexEntry(
      id: MeetingID(
        rawValue: UUID(uuidString: "A1111111-1111-1111-1111-111111111111")!
      ),
      createdAt: Date(),
      relativeDirectory: "meeting-search",
      assets: [.transcript, .minutes],
      title: "Search result",
      modelName: "deepseek-chat"
    )
    let snapshot = MeetingLibrarySnapshot(
      directory: .fixture,
      meetings: [result],
      diagnosticCount: 0
    )
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .success(snapshot),
        searchRecorder: recorder,
        searchResult: [result]
      )
    )
    await model.load()
    model.searchText = "季度复盘"
    model.dateFilter = .lastSevenDays
    model.selectedStatuses = [.minutesCompleted]
    model.selectedModelName = "deepseek-chat"

    await model.applySearch()

    let query = await recorder.lastQuery
    #expect(query?.text == "季度复盘")
    #expect(query?.createdFrom != nil)
    #expect(query?.createdThrough != nil)
    #expect(query?.statuses == [.minutesCompleted])
    #expect(query?.modelName == "deepseek-chat")
    #expect(model.state == .loaded(snapshot))
  }

  @Test("Date filters use the injected clock and calendar")
  func deterministicDateFilter() async {
    let recorder = SearchQueryRecorder()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .success(.fixture),
        searchRecorder: recorder
      ),
      now: { now },
      calendar: calendar
    )
    await model.load()
    model.dateFilter = .today

    await model.applySearch()

    let query = await recorder.lastQuery
    #expect(query?.createdFrom == calendar.startOfDay(for: now))
    #expect(
      query?.createdThrough
        == calendar.date(
          byAdding: .day,
          value: 1,
          to: calendar.startOfDay(for: now)
        )
    )
  }

  @Test("Periodic synchronization belongs to the model and stops at cancellation")
  func periodicSynchronization() async {
    let recorder = SynchronizationRecorder()
    let waiter = SynchronizationWaiter()
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .success(.fixture),
        synchronizationRecorder: recorder
      ),
      waitForSynchronization: waiter.wait
    )
    await model.load()
    while await recorder.callCount == 0 {
      await Task.yield()
    }
    await recorder.reset()

    await model.synchronizeUntilCancelled()

    #expect(await recorder.callCount == 1)
  }

  @Test("An iCloud placeholder keeps the last indexed snapshot visible")
  func iCloudPlaceholderPreservesSnapshot() async {
    let snapshot = MeetingLibrarySnapshot.fixture
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .success(snapshot),
        synchronizeResult: .failure(DirectoryAccessError.itemNotDownloaded)
      )
    )

    await model.load()
    await model.synchronizeExternalChanges()

    #expect(model.state == .loaded(snapshot))
  }

  private func makeModel(
    library: any MeetingLibraryUseCase,
    transcriptionRecovery: (any TranscriptionRecoveryUseCase)? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    calendar: Calendar = .current,
    waitForSynchronization: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(15))
    }
  ) -> MeetingsModel {
    MeetingsModel(
      library: library,
      transcriptionRecovery: transcriptionRecovery,
      detail: UnusedMeetingDetailUseCase(),
      makePlayer: {
        UnusedMeetingAudioPlayer()
      },
      now: now,
      calendar: calendar,
      waitForSynchronization: waitForSynchronization
    )
  }
}

private struct UnusedMeetingDetailUseCase: MeetingDetailUseCase {
  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    throw CancellationError()
  }
}

@MainActor
private final class UnusedMeetingAudioPlayer: MeetingAudioPlayer {
  private let snapshotValue = MeetingAudioPlaybackSnapshot(
    durationSeconds: 0,
    currentSeconds: 0,
    isPlaying: false
  )

  func load(_ asset: MeetingAudioAsset) async throws -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func play() throws -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func pause() -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func seek(to seconds: Double) throws -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func snapshot() -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func unload() async {}
}

private actor TranscriptionRecoveryUseCaseStub: TranscriptionRecoveryUseCase {
  private(set) var callCount = 0

  func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    callCount += 1
    return []
  }
}

private struct MeetingLibraryUseCaseStub: MeetingLibraryUseCase {
  let restoreResult: Result<MeetingLibrarySnapshot, Error>
  var searchRecorder: SearchQueryRecorder?
  var searchResult: [MeetingIndexEntry]?
  var synchronizeResult: Result<MeetingLibrarySnapshot, Error>?
  var synchronizationRecorder: SynchronizationRecorder?

  init(
    restoreResult: Result<MeetingLibrarySnapshot, Error>,
    searchRecorder: SearchQueryRecorder? = nil,
    searchResult: [MeetingIndexEntry]? = nil,
    synchronizeResult: Result<MeetingLibrarySnapshot, Error>? = nil,
    synchronizationRecorder: SynchronizationRecorder? = nil
  ) {
    self.restoreResult = restoreResult
    self.searchRecorder = searchRecorder
    self.searchResult = searchResult
    self.synchronizeResult = synchronizeResult
    self.synchronizationRecorder = synchronizationRecorder
  }

  func restore() async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func synchronize() async throws -> MeetingLibrarySnapshot {
    await synchronizationRecorder?.record()
    return try (synchronizeResult ?? restoreResult).get()
  }

  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry] {
    await searchRecorder?.record(query)
    if let searchResult {
      return searchResult
    }
    return try restoreResult.get().meetings
  }
}

private actor SearchQueryRecorder {
  private(set) var lastQuery: MeetingSearchQuery?

  func record(_ query: MeetingSearchQuery) {
    lastQuery = query
  }
}

private actor SynchronizationRecorder {
  private(set) var callCount = 0

  func record() {
    callCount += 1
  }

  func reset() {
    callCount = 0
  }
}

private final class SynchronizationWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var hasReturned = false

  func wait() async throws {
    let shouldReturn = lock.withLock {
      guard !hasReturned else {
        return false
      }
      hasReturned = true
      return true
    }
    if !shouldReturn {
      throw CancellationError()
    }
  }
}

extension MeetingLibrarySnapshot {
  fileprivate static let fixture = Self(
    directory: AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "test"),
      displayName: "Vault",
      kind: .userSelected
    ),
    meetings: [],
    diagnosticCount: 0
  )
}

extension AuthoritativeDirectory {
  fileprivate static let fixture = Self(
    id: AuthoritativeDirectoryID(rawValue: "test"),
    displayName: "Vault",
    kind: .userSelected
  )
}
