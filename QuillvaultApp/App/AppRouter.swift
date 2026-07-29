import AppNavigation
import Observation

@MainActor
@Observable
final class AppRouter {
  var selectedTab: AppTab

  init(selectedTab: AppTab = .home) {
    self.selectedTab = selectedTab
  }
}
