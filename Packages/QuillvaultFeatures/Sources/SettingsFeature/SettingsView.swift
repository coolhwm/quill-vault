import DesignSystem
import SwiftUI

public struct SettingsView: View {
  public init() {}

  public var body: some View {
    List {
      Section("settings.about.section") {
        Label("settings.local.first", systemImage: "iphone.and.arrow.forward")
        Label("settings.privacy", systemImage: "hand.raised")
      }
    }
    .navigationTitle("settings.navigation.title")
    .accessibilityIdentifier("settings.screen")
  }
}
