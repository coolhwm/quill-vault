import AppNavigation
import Testing

@Suite("App tab contract")
struct AppTabTests {
  @Test("MVP exposes exactly the three product areas in their scan order")
  func exposesProductAreas() {
    #expect(AppTab.allCases == [.home, .minutes, .settings])
  }

  @Test("Each product area has stable navigation and accessibility metadata")
  func exposesStableMetadata() {
    #expect(AppTab.home.id == "home")
    #expect(AppTab.home.systemImage == "house")
    #expect(AppTab.minutes.id == "minutes")
    #expect(AppTab.minutes.systemImage == "doc.text")
    #expect(AppTab.settings.id == "settings")
    #expect(AppTab.settings.systemImage == "gearshape")
  }
}
