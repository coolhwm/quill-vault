import SwiftUI

@main
struct QuillvaultApp: App {
  @State private var compositionRoot = AppCompositionRoot()

  var body: some Scene {
    WindowGroup {
      AppRootView(router: compositionRoot.router)
    }
  }
}
