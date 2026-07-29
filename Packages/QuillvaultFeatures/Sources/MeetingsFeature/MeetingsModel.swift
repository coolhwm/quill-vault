import Application
import Domain
import Observation

@MainActor
@Observable
public final class MeetingsModel {
  public private(set) var state: MeetingLibraryState = .idle

  private let library: any MeetingLibraryUseCase

  public init(library: any MeetingLibraryUseCase) {
    self.library = library
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

  private func recovery(for error: Error) -> MeetingLibraryRecovery {
    guard let accessError = error as? DirectoryAccessError else {
      return .tryAgain
    }
    switch accessError {
    case .bookmarkMissing, .bookmarkStale, .directoryMoved, .permissionDenied:
      return .renewAccess
    case .itemNotDownloaded:
      return .downloadRequired
    case .iCloudUnavailable:
      return .chooseDirectory
    case .coordinationFailed, .invalidSelection, .unreadableDirectory:
      return .tryAgain
    }
  }
}
