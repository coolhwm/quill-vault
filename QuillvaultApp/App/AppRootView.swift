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
        HomeView(model: recordingModel) { meetingID in
          router.openMeetingDetail(meetingID)
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
        ProfileView(model: profileModel) {
          SettingsView(model: settingsModel)
        }
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
          await openPendingMeetingIfNeeded()
        case .profile:
          await profileModel.load()
          await settingsModel.load()
        }
      }
    }
    .onChange(of: router.pendingMeetingID) { _, pending in
      guard pending != nil, router.selectedTab == .minutes else {
        return
      }
      Task {
        await meetingsModel.load()
        await openPendingMeetingIfNeeded()
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

  @MainActor
  private func openPendingMeetingIfNeeded() async {
    guard let meetingID = router.consumePendingMeetingID() else {
      return
    }
    await meetingsModel.openDetail(for: meetingID)
  }
}
