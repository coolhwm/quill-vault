import Application
import Foundation
import Testing

@Suite("Model provider catalog")
struct ModelProviderCatalogTests {
  @Test("Catalog exposes versioned OpenAI-compatible presets")
  func exposesPresets() {
    #expect(ModelProviderCatalog.version == "v1")
    #expect(ModelProviderCatalog.all.count >= 3)
    #expect(ModelProviderCatalog.preset(id: "openai")?.displayName == "OpenAI")
    #expect(
      ModelProviderCatalog.matchingPreset(
        baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!
      )?.id == "deepseek"
    )
  }

  @Test("Custom mode is not a network preset identity")
  func customIsNotPreset() {
    #expect(ModelProviderCatalog.preset(id: ModelProviderCatalog.customID) == nil)
  }
}
