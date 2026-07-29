import AppNavigation
import HomeFeature
import MeetingsFeature
import SettingsFeature
import SwiftUI

struct AppRootView: View {
  @Bindable var router: AppRouter

  var body: some View {
    TabView(selection: $router.selectedTab) {
      NavigationStack {
        HomeView()
      }
      .tabItem {
        Label("tab.home", systemImage: AppTab.home.systemImage)
      }
      .tag(AppTab.home)

      NavigationStack {
        MeetingsView()
      }
      .tabItem {
        Label("tab.minutes", systemImage: AppTab.minutes.systemImage)
      }
      .tag(AppTab.minutes)

      NavigationStack {
        SettingsView()
      }
      .tabItem {
        Label("tab.settings", systemImage: AppTab.settings.systemImage)
      }
      .tag(AppTab.settings)
    }
    .tint(.accentColor)
  }
}
