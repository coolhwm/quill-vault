import AppNavigation
import Domain
import Observation

@MainActor
@Observable
final class AppRouter {
  var selectedTab: AppTab
  /// When set, the Meetings tab should open this meeting's detail.
  var pendingMeetingID: MeetingID?

  init(selectedTab: AppTab = .home) {
    self.selectedTab = selectedTab
  }

  func openMeetingDetail(_ meetingID: MeetingID) {
    pendingMeetingID = meetingID
    selectedTab = .minutes
  }

  func consumePendingMeetingID() -> MeetingID? {
    let id = pendingMeetingID
    pendingMeetingID = nil
    return id
  }
}
