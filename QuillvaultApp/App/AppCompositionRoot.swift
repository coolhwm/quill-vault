import Application
import Foundation
import MeetingFileStore
import MeetingsFeature
import Observation
import PersistenceGRDB

@MainActor
@Observable
final class AppCompositionRoot {
  let router: AppRouter
  let meetingsModel: MeetingsModel

  init(
    router: AppRouter = AppRouter(),
    meetingLibrary: (any MeetingLibraryUseCase)? = nil
  ) {
    self.router = router
    meetingsModel = MeetingsModel(
      library: meetingLibrary ?? Self.makeMeetingLibrary()
    )
  }

  private static func makeMeetingLibrary() -> any MeetingLibraryUseCase {
    RetryingMeetingLibraryUseCase {
      try buildMeetingLibrary()
    }
  }

  nonisolated private static func buildMeetingLibrary()
    throws -> any MeetingLibraryUseCase
  {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let databaseURL =
      applicationSupport
      .appending(path: "Quillvault", directoryHint: .isDirectory)
      .appending(path: "meeting-catalog.sqlite")
    let catalog = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    return MeetingLibraryWorkflow(
      directoryAccess: MeetingFileStore(),
      catalog: catalog
    )
  }
}
