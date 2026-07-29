import Observation

@MainActor
@Observable
final class AppCompositionRoot {
  let router: AppRouter

  init(router: AppRouter = AppRouter()) {
    self.router = router
  }
}
