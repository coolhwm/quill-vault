import Foundation

/// Strategy resource describing a BYOK vendor preset. Adding a vendor is a
/// catalog change only — generation and networking keep using profile fields.
public struct ModelProviderPreset: Equatable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let defaultBaseURL: URL
  public let recommendedModels: [String]
  public let supportsStreaming: Bool
  public let configurationHint: String

  public init(
    id: String,
    displayName: String,
    defaultBaseURL: URL,
    recommendedModels: [String],
    supportsStreaming: Bool,
    configurationHint: String
  ) {
    self.id = id
    self.displayName = displayName
    self.defaultBaseURL = defaultBaseURL
    self.recommendedModels = recommendedModels
    self.supportsStreaming = supportsStreaming
    self.configurationHint = configurationHint
  }
}

public enum ModelProviderCatalog {
  public static let version = "v2"

  public static let customID = "custom"

  public static let all: [ModelProviderPreset] = [
    ModelProviderPreset(
      id: "openai",
      displayName: "OpenAI",
      defaultBaseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
      recommendedModels: ["gpt-4.1-mini", "gpt-4.1", "o4-mini"],
      supportsStreaming: true,
      configurationHint: "OpenAI-compatible Chat Completions endpoint."
    ),
    ModelProviderPreset(
      id: "deepseek",
      displayName: "DeepSeek",
      defaultBaseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
      recommendedModels: ["deepseek-chat", "deepseek-reasoner"],
      supportsStreaming: true,
      configurationHint: "DeepSeek OpenAI-compatible endpoint."
    ),
    ModelProviderPreset(
      id: "siliconflow",
      displayName: "SiliconFlow",
      defaultBaseURL: URL(string: "https://api.siliconflow.cn/v1/chat/completions")!,
      recommendedModels: [
        "deepseek-ai/DeepSeek-V3",
        "Qwen/Qwen2.5-72B-Instruct",
        "Qwen/Qwen2.5-7B-Instruct",
      ],
      supportsStreaming: true,
      configurationHint: "SiliconFlow OpenAI-compatible gateway."
    ),
    ModelProviderPreset(
      id: "moonshot",
      displayName: "Moonshot / Kimi",
      defaultBaseURL: URL(string: "https://api.moonshot.cn/v1/chat/completions")!,
      recommendedModels: ["moonshot-v1-8k", "moonshot-v1-32k", "kimi-latest"],
      supportsStreaming: true,
      configurationHint: "Moonshot OpenAI-compatible endpoint."
    ),
  ]

  public static func preset(id: String) -> ModelProviderPreset? {
    all.first(where: { $0.id == id })
  }

  /// Matches a saved base URL to a known preset when possible.
  public static func matchingPreset(baseURL: URL) -> ModelProviderPreset? {
    let host = baseURL.host?.lowercased()
    return all.first { $0.defaultBaseURL.host?.lowercased() == host }
  }

  /// Built-in recommended models for a preset (always available offline).
  public static func builtInModels(for presetID: String) -> [String] {
    preset(id: presetID)?.recommendedModels ?? []
  }

  /// Derives an OpenAI-compatible `/models` URL from a chat completions base URL.
  public static func modelsListURL(fromChatCompletionsURL baseURL: URL) -> URL? {
    var path = baseURL.path
    if path.hasSuffix("/chat/completions") {
      path = String(path.dropLast("/chat/completions".count)) + "/models"
    } else if path.hasSuffix("/v1") {
      path = path + "/models"
    } else if path.isEmpty || path == "/" {
      path = "/v1/models"
    } else {
      path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      path = "/\(path)/models"
    }
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = path
    components?.query = nil
    components?.fragment = nil
    return components?.url
  }

  /// Parses an OpenAI-compatible models list JSON payload into model ids.
  public static func parseModelsListJSON(_ data: Data) -> [String] {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = object["data"] as? [[String: Any]]
    else {
      return []
    }
    var ids: [String] = []
    var seen = Set<String>()
    for item in items {
      guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else {
        continue
      }
      ids.append(id)
    }
    return ids.sorted()
  }

  /// Merges remote model ids with built-in recommendations (built-ins first).
  public static func mergeRecommended(
    builtIn: [String],
    remote: [String]
  ) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for id in builtIn + remote {
      guard !id.isEmpty, seen.insert(id).inserted else { continue }
      result.append(id)
    }
    return result
  }
}
