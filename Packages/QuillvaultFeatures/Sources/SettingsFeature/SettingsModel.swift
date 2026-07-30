import Application
import Domain
import Observation

public enum SettingsDirectoryState: Equatable, Sendable {
  case checking
  case recoveryRequired(AuthoritativeDirectoryRecovery)
  case authorized(AuthoritativeDirectory)
}

@MainActor
@Observable
public final class SettingsModel {
  public private(set) var directoryState: SettingsDirectoryState = .checking

  private let directory: any AuthoritativeDirectoryUseCase
  private let library: any MeetingLibraryUseCase

  public init(
    directory: any AuthoritativeDirectoryUseCase,
    library: any MeetingLibraryUseCase
  ) {
    self.directory = directory
    self.library = library
  }

  public func load() async {
    do {
      guard let authorized = try await directory.restore() else {
        directoryState = .recoveryRequired(.chooseDirectory)
        return
      }
      directoryState = .authorized(authorized)
    } catch {
      directoryState = .recoveryRequired(recovery(for: error))
    }
  }

  public func selectDirectory(opaqueReference: String) async {
    directoryState = .checking
    do {
      let snapshot = try await library.select(
        AuthoritativeDirectorySelection(
          opaqueReference: opaqueReference
        )
      )
      directoryState = .authorized(snapshot.directory)
    } catch {
      directoryState = .recoveryRequired(recovery(for: error))
    }
  }

  private func recovery(for error: Error) -> AuthoritativeDirectoryRecovery {
    (error as? DirectoryAccessError)?.recovery ?? .tryAgain
  }
}
