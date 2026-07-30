import AppNavigation
import HomeFeature
import MeetingsFeature
import SettingsFeature
import SwiftUI

struct AppRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var router: AppRouter
  let recordingModel: HomeRecordingModel
  let meetingsModel: MeetingsModel
  let settingsModel: SettingsModel
  let lifecycleCoordinator: AppLifecycleCoordinator

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
        SettingsView(model: settingsModel)
      }
      .tabItem {
        Label("tab.settings", systemImage: AppTab.settings.systemImage)
      }
      .tag(AppTab.settings)
    }
    .tint(.accentColor)
    .onChange(of: router.selectedTab) { _, selectedTab in
      Task {
        switch selectedTab {
        case .home:
          await recordingModel.refreshDirectory()
        case .minutes:
          await meetingsModel.load()
        case .settings:
          await settingsModel.load()
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else {
        return
      }
      Task {
        await lifecycleCoordinator.didBecomeActive()
      }
    }
  }
}
