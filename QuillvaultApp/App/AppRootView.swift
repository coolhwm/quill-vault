import AppNavigation
import HomeFeature
import MeetingsFeature
import ProfileFeature
import SettingsFeature
import SwiftUI

struct AppRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var router: AppRouter
  let recordingModel: HomeRecordingModel
  let meetingsModel: MeetingsModel
  let profileModel: ProfileModel
  let settingsModel: SettingsModel
  let lifecycleCoordinator: AppLifecycleCoordinator

  var body: some View {
    TabView(selection: $router.selectedTab) {
      NavigationStack {
        HomeView(model: recordingModel) { _ in
          router.selectedTab = .minutes
        }
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
        ProfileView(model: profileModel, settingsModel: settingsModel)
      }
      .tabItem {
        Label("tab.profile", systemImage: AppTab.profile.systemImage)
      }
      .tag(AppTab.profile)
    }
    .tint(.accentColor)
    .preferredColorScheme(interfaceStyleOverride)
    .onChange(of: router.selectedTab) { _, selectedTab in
      Task {
        switch selectedTab {
        case .home:
          await recordingModel.refreshDirectory()
        case .minutes:
          await meetingsModel.load()
        case .profile:
          await profileModel.load()
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
    .task {
      await lifecycleCoordinator.didBecomeActive()
    }
  }

  private var interfaceStyleOverride: ColorScheme? {
    if ProcessInfo.processInfo.arguments.contains("-ui-test-dark-mode") {
      return .dark
    }
    if ProcessInfo.processInfo.arguments.contains("-ui-test-light-mode") {
      return .light
    }
    return nil
  }
}
