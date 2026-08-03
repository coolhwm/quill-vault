import Application
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingsModel {
  private(set) var state: MeetingLibraryState = .idle
  private(set) var recoveringMeetingID: MeetingID?
  private(set) var isSearching = false
  var searchText = ""
  var dateFilter: MeetingDateFilter = .all
  var selectedStatuses: Set<MeetingIndexStatus> = []
  var selectedModelName: String?

  private let library: any MeetingLibraryUseCase
  private let transcriptionRecovery: (any TranscriptionRecoveryUseCase)?
  private let detail: any MeetingDetailUseCase
  private let generation: (any GenerationUseCase)?
  private let makePlayer: @MainActor () -> any MeetingAudioPlayer
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private let waitForSynchronization: @Sendable () async throws -> Void
  private var unfilteredSnapshot: MeetingLibrarySnapshot?
  private var isSynchronizing = false

  public init(
    library: any MeetingLibraryUseCase,
    transcriptionRecovery: (any TranscriptionRecoveryUseCase)? = nil,
    detail: any MeetingDetailUseCase,
    makePlayer: @escaping @MainActor () -> any MeetingAudioPlayer,
    generation: (any GenerationUseCase)? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    calendar: Calendar = .current,
    waitForSynchronization: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(15))
    }
  ) {
    self.library = library
    self.transcriptionRecovery = transcriptionRecovery
    self.detail = detail
    self.generation = generation
    self.makePlayer = makePlayer
    self.now = now
    self.calendar = calendar
    self.waitForSynchronization = waitForSynchronization
  }

  public func makeDetailModel(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) -> MeetingDetailModel {
    return MeetingDetailModel(
      directory: directory,
      meeting: meeting,
      detail: detail,
      player: makePlayer(),
      generation: generation
    )
  }

  public func load() async {
    state = .loading
    do {
      setLoaded(try await library.restore())
      Task { [weak self] in
        await self?.synchronizeExternalChanges()
      }
    } catch {
      state = .failed(recovery(for: error))
    }
  }

  public func selectDirectory(opaqueReference: String) async {
    state = .loading
    do {
      setLoaded(
        try await library.select(
          AuthoritativeDirectorySelection(
            opaqueReference: opaqueReference
          )
        )
      )
    } catch {
      state = .failed(recovery(for: error))
    }
  }

  public func rebuild() async {
    state = .loading
    do {
      setLoaded(try await library.rebuild())
    } catch {
      state = .failed(recovery(for: error))
    }
  }

  public func synchronizeExternalChanges() async {
    guard let currentSnapshot = unfilteredSnapshot, !isSynchronizing else {
      return
    }
    isSynchronizing = true
    defer { isSynchronizing = false }
    do {
      let synchronizedSnapshot = try await library.synchronize()
      guard synchronizedSnapshot != currentSnapshot else {
        return
      }
      setLoaded(synchronizedSnapshot)
      if hasActiveSearch {
        await applySearch()
      }
    } catch is CancellationError {
      return
    } catch DirectoryAccessError.itemNotDownloaded {
      return
    } catch {
      state = .failed(recovery(for: error))
    }
  }

  public func retryTranscript(meetingID: MeetingID) async {
    guard let transcriptionRecovery, recoveringMeetingID == nil else {
      return
    }
    recoveringMeetingID = meetingID
    do {
      _ = try await transcriptionRecovery.recoverPendingTranscriptions()
    } catch {
      recoveringMeetingID = nil
      state = .failed(.tryAgain)
      return
    }
    recoveringMeetingID = nil
    await rebuild()
  }

  var availableModelNames: [String] {
    Array(
      Set(unfilteredSnapshot?.meetings.compactMap(\.modelName) ?? [])
    ).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  var searchQuery: MeetingSearchQuery {
    let bounds = dateFilter.bounds(reference: now(), calendar: calendar)
    return MeetingSearchQuery(
      text: searchText,
      createdFrom: bounds.start,
      createdThrough: bounds.end,
      statuses: selectedStatuses,
      modelName: selectedModelName
    )
  }

  var searchSelection: MeetingSearchSelection {
    MeetingSearchSelection(
      text: searchText,
      dateFilter: dateFilter,
      statuses: selectedStatuses,
      modelName: selectedModelName
    )
  }

  var hasActiveSearch: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || dateFilter != .all
      || !selectedStatuses.isEmpty
      || selectedModelName != nil
  }

  func applySearch() async {
    guard let unfilteredSnapshot else {
      return
    }
    guard hasActiveSearch else {
      let unfilteredState = MeetingLibraryState.loaded(unfilteredSnapshot)
      if state != unfilteredState {
        state = unfilteredState
      }
      return
    }
    isSearching = true
    defer { isSearching = false }
    do {
      let meetings = try await library.search(searchQuery)
      state = .loaded(
        MeetingLibrarySnapshot(
          directory: unfilteredSnapshot.directory,
          meetings: meetings,
          diagnosticCount: unfilteredSnapshot.diagnosticCount
        )
      )
    } catch is CancellationError {
      return
    } catch {
      state = .failed(.tryAgain)
    }
  }

  func toggleStatus(_ status: MeetingIndexStatus) {
    if selectedStatuses.contains(status) {
      selectedStatuses.remove(status)
    } else {
      selectedStatuses.insert(status)
    }
  }

  func clearFilters() {
    searchText = ""
    dateFilter = .all
    selectedStatuses = []
    selectedModelName = nil
    if let unfilteredSnapshot {
      state = .loaded(unfilteredSnapshot)
    }
  }

  func synchronizeUntilCancelled() async {
    while !Task.isCancelled {
      do {
        try await waitForSynchronization()
      } catch {
        return
      }
      guard !Task.isCancelled else {
        return
      }
      await synchronizeExternalChanges()
    }
  }

  private func setLoaded(_ snapshot: MeetingLibrarySnapshot) {
    unfilteredSnapshot = snapshot
    state = .loaded(snapshot)
  }

  private func recovery(for error: Error) -> MeetingLibraryRecovery {
    guard let accessError = error as? DirectoryAccessError else {
      return .tryAgain
    }
    switch accessError {
    case .bookmarkMissing:
      return .chooseDirectory
    case .bookmarkStale, .directoryMoved, .permissionDenied:
      return .renewAccess
    case .itemNotDownloaded:
      return .downloadRequired
    case .coordinationFailed, .invalidSelection, .unreadableDirectory:
      return .tryAgain
    }
  }
}

enum MeetingDateFilter: String, CaseIterable, Sendable {
  case all
  case today
  case lastSevenDays
  case lastThirtyDays

  fileprivate func bounds(
    reference: Date,
    calendar: Calendar = .current
  ) -> (start: Date?, end: Date?) {
    switch self {
    case .all:
      return (nil, nil)
    case .today:
      return (
        calendar.startOfDay(for: reference),
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))
      )
    case .lastSevenDays:
      return (calendar.date(byAdding: .day, value: -7, to: reference), reference)
    case .lastThirtyDays:
      return (calendar.date(byAdding: .day, value: -30, to: reference), reference)
    }
  }
}

struct MeetingSearchSelection: Hashable, Sendable {
  let text: String
  let dateFilter: MeetingDateFilter
  let statuses: Set<MeetingIndexStatus>
  let modelName: String?
}
