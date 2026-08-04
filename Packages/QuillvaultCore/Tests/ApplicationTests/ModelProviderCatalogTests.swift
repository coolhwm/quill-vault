import Application
import Foundation
import Testing

@Suite("Model provider catalog")
struct ModelProviderCatalogTests {
  @Test("Catalog exposes versioned OpenAI-compatible presets")
  func exposesPresets() {
    #expect(ModelProviderCatalog.version == "v2")
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

  @Test("Models list URL derives from chat completions endpoint")
  func modelsListURL() {
    let chat = URL(string: "https://api.deepseek.com/v1/chat/completions")!
    #expect(
      ModelProviderCatalog.modelsListURL(fromChatCompletionsURL: chat)?
        .absoluteString == "https://api.deepseek.com/v1/models"
    )
  }

  @Test("Parses OpenAI models list and merges with built-ins")
  func parseAndMergeModels() throws {
    let json = """
      {"data":[{"id":"remote-a"},{"id":"gpt-4.1-mini"},{"id":"remote-b"}]}
      """
    let remote = ModelProviderCatalog.parseModelsListJSON(Data(json.utf8))
    #expect(remote.contains("remote-a"))
    let merged = ModelProviderCatalog.mergeRecommended(
      builtIn: ["gpt-4.1-mini", "gpt-4.1"],
      remote: remote
    )
    #expect(merged.first == "gpt-4.1-mini")
    #expect(merged.contains("remote-b"))
    #expect(Set(merged).count == merged.count)
  }
}
