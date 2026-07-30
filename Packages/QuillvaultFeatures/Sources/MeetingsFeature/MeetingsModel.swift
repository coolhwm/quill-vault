import Application
import Domain
import Observation

@MainActor
@Observable
public final class MeetingsModel {
  public private(set) var state: MeetingLibraryState = .idle
  public private(set) var recoveringMeetingID: MeetingID?

  private let library: any MeetingLibraryUseCase
  private let transcriptionRecovery: (any TranscriptionRecoveryUseCase)?

  public init(
    library: any MeetingLibraryUseCase,
    transcriptionRecovery: (any TranscriptionRecoveryUseCase)? = nil
  ) {
    self.library = library
    self.transcriptionRecovery = transcriptionRecovery
  }

  public func load() async {
    state = .loading
    do {
      state = .loaded(try await library.restore())
    } catch {
      state = .failed(recovery(for: error))
    }
  }

  public func selectDirectory(opaqueReference: String) async {
    state = .loading
    do {
      state = .loaded(
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
      state = .loaded(try await library.rebuild())
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
