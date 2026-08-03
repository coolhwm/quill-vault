import Application
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class ProfileModel {
  public private(set) var stats: MeetingStats = .empty
  public private(set) var isLoading = false
  public private(set) var loadFailed = false

  private let library: any MeetingLibraryUseCase
  private let calendar: Calendar
  private let now: () -> Date

  public init(
    library: any MeetingLibraryUseCase,
    calendar: Calendar = .current,
    now: @escaping () -> Date = Date.init
  ) {
    self.library = library
    self.calendar = calendar
    self.now = now
  }

  public func load() async {
    isLoading = true
    loadFailed = false
    defer { isLoading = false }
    do {
      let snapshot = try await library.restore()
      stats = MeetingStats.make(
        from: snapshot.meetings,
        now: now(),
        calendar: calendar
      )
    } catch {
      loadFailed = true
      stats = .empty
    }
  }
}
