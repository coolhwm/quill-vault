import AppNavigation
import HomeFeature
import MeetingsFeature
import SettingsFeature
import SwiftUI

struct AppRootView: View {
  @Bindable var router: AppRouter
  let recordingModel: HomeRecordingModel
  let meetingsModel: MeetingsModel

  var body: some View {
    TabView(selection: $router.selectedTab) {
      NavigationStack {
        HomeView(model: recordingModel)
      }
      .tabItem {
        Label("tab.home", systemImage: AppTab.home.systemImage)
      }
      .tag(AppTab.home)

      NavigationStack {
        MeetingsView(model: meetingsModel)
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
