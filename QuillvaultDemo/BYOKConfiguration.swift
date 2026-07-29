import Foundation
import Security

// MARK: - Settings models

struct BYOKSettings: Equatable, Sendable {
    var baseURL: String
    var model: String
    /// Editing field only. Never filled from Keychain with the full secret after save.
    var apiKeyField: String
    var hasStoredAPIKey: Bool

    static let deepSeekDefaults = BYOKSettings(
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-pro",
        apiKeyField: "",
        hasStoredAPIKey: false
    )
}

enum BYOKConnectionTestState: Equatable, Sendable {
    case idle
    case testing
    case succeeded(String)
    case failed(String)
}

struct BYOKProbeResult: Equatable, Sendable {
    let title: String
    let overview: String
    let summary: String
}

// MARK: - Narrow replaceable boundaries

@MainActor
protocol APIKeyStoring: AnyObject {
    func save(_ key: String) throws
    func load() throws -> String?
    func hasKey() -> Bool
}

@MainActor
protocol BYOKPreferencesStoring: AnyObject {
    var baseURL: String { get set }
    var model: String { get set }
}

@MainActor
protocol BYOKConnectionTesting: AnyObject {
    func testConnection(baseURL: String, model: String, apiKey: String) async throws -> String
}

protocol HTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func stream(
        for request: URLRequest,
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws -> URLResponse
}

extension HTTPTransporting {
    /// Test transports that only implement data(for:) remain usable and exercise the
    /// non-streaming compatibility path.
    func stream(
        for request: URLRequest,
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws -> URLResponse {
        let (data, response) = try await data(for: request)
        if let text = String(data: data, encoding: .utf8) {
            try await onLine(text)
        }
        return response
    }
}

// MARK: - Errors

enum BYOKConnectionError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL
    case missingModel
    case authenticationFailed
    case modelNotFound
    case networkFailure(String)
    case storageFailure(String)
    case emptyContent
    case invalidJSON
    case invalidStructure
    case httpFailure(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "请先输入 API Key，或确认 Keychain 中已有保存的密钥。"
        case .invalidBaseURL:
            "Base URL 无效，请使用类似 https://api.deepseek.com 的地址。"
        case .missingModel:
            "请填写 Model 名称（验收目标：deepseek-v4-pro）。"
        case .authenticationFailed:
            "认证失败：API Key 被拒绝，请检查密钥。"
        case .modelNotFound:
            "模型不存在或不可用，请检查 Model 名称。"
        case let .networkFailure(detail):
            "网络错误：\(detail)"
        case let .storageFailure(detail):
            "本地存储失败：\(detail)"
        case .emptyContent:
            "连接测试失败：模型返回空内容。HTTP 成功不足以判定通过。"
        case .invalidJSON:
            "连接测试失败：模型返回无法解析的 JSON。"
        case .invalidStructure:
            "连接测试失败：JSON 合法但缺少代表性业务字段（title / overview / summary）。"
        case let .httpFailure(statusCode, detail):
            "服务返回 HTTP \(statusCode)：\(detail)"
        }
    }
}

// MARK: - In-memory substitutes (tests / controlled demo)

@MainActor
final class InMemoryAPIKeyStore: APIKeyStoring {
    private var value: String?

    init(initial: String? = nil) {
        self.value = initial
    }

    func save(_ key: String) throws {
        value = key
    }

    func load() throws -> String? {
        value
    }

    func hasKey() -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }
}

@MainActor
final class InMemoryBYOKPreferences: BYOKPreferencesStoring {
    var baseURL: String
    var model: String

    init(
        baseURL: String = BYOKSettings.deepSeekDefaults.baseURL,
        model: String = BYOKSettings.deepSeekDefaults.model
    ) {
        self.baseURL = baseURL
        self.model = model
    }
}

@MainActor
final class StoreBackedCredentialChecker: BYOKCredentialChecking {
    private let store: any APIKeyStoring

    init(store: any APIKeyStoring) {
        self.store = store
    }

    func hasBYOKCredential() async -> Bool {
        store.hasKey()
    }
}

// MARK: - Live stores

@MainActor
final class KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.coolhwm.QuillvaultDemo.byok",
        account: String = "deepseek-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BYOKConnectionError.storageFailure("Keychain 保存失败（\(status)）")
        }
    }

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw BYOKConnectionError.storageFailure("Keychain 读取失败（\(status)）")
        }
        return String(data: data, encoding: .utf8)
    }

    func hasKey() -> Bool {
        (try? load())?.isEmpty == false
    }
}

@MainActor
final class UserDefaultsBYOKPreferences: BYOKPreferencesStoring {
    private let defaults: UserDefaults
    private let baseURLKey = "byok.baseURL"
    private let modelKey = "byok.model"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var baseURL: String {
        get {
            let value = defaults.string(forKey: baseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
            return BYOKSettings.deepSeekDefaults.baseURL
        }
        set {
            defaults.set(newValue, forKey: baseURLKey)
        }
    }

    var model: String {
        get {
            let value = defaults.string(forKey: modelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
            return BYOKSettings.deepSeekDefaults.model
        }
        set {
            defaults.set(newValue, forKey: modelKey)
        }
    }
}

// MARK: - Request / response helpers

enum BYOKRequestPurpose {
    case connectionProbe
    case minutesGeneration

    var timeoutInterval: TimeInterval {
        switch self {
        case .connectionProbe: 45
        case .minutesGeneration: 90
        }
    }
}

enum BYOKConnectionRequestBuilder {
    static func makeURLRequest(
        baseURL: String,
        model: String,
        apiKey: String,
        purpose: BYOKRequestPurpose = .connectionProbe
    ) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed) else {
            throw BYOKConnectionError.invalidBaseURL
        }
        if components.scheme == nil {
            throw BYOKConnectionError.invalidBaseURL
        }
        let path = components.path
        if path.hasSuffix("/v1/chat/completions") {
            // keep as-is
        } else if path.hasSuffix("/v1") {
            components.path = path + "/chat/completions"
        } else if path.isEmpty || path == "/" {
            components.path = "/v1/chat/completions"
        } else {
            components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + components.path + "/v1/chat/completions"
        }
        guard let url = components.url else {
            throw BYOKConnectionError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = purpose.timeoutInterval

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": """
                    你是连接测试助手。只返回 JSON 对象，不要 Markdown。
                    必须包含非空字符串字段 title、overview、summary。
                    """
                ],
                [
                    "role": "user",
                    "content": "请返回一次 BYOK 连接探测结果，用于验证结构化纪要字段。"
                ]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum BYOKProbeValidator {
    static func validate(content: String) throws -> BYOKProbeResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BYOKConnectionError.emptyContent
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw BYOKConnectionError.invalidJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BYOKConnectionError.invalidJSON
        }
        guard let dict = object as? [String: Any] else {
            throw BYOKConnectionError.invalidStructure
        }
        guard
            let title = nonEmptyString(dict["title"]),
            let overview = nonEmptyString(dict["overview"]),
            let summary = nonEmptyString(dict["summary"])
        else {
            throw BYOKConnectionError.invalidStructure
        }
        return BYOKProbeResult(title: title, overview: overview, summary: summary)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum BYOKHTTPResponseMapper {
    static func content(from data: Data, response: URLResponse) throws -> String {
        if let mapped = map(data: data, response: response) {
            throw mapped
        }
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = envelope?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BYOKConnectionError.emptyContent
        }
        return content
    }

    /// Returns a mapped error when the HTTP/body shape is not a successful probe payload.
    static func map(data: Data, response: URLResponse) -> Error? {
        guard let http = response as? HTTPURLResponse else {
            return BYOKConnectionError.networkFailure("非 HTTP 响应")
        }
        switch http.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            return BYOKConnectionError.authenticationFailed
        case 404:
            return BYOKConnectionError.modelNotFound
        default:
            let detail = String(data: data, encoding: .utf8) ?? "无响应体"
            let lower = detail.lowercased()
            if lower.contains("model") && (lower.contains("not") || lower.contains("exist") || lower.contains("invalid")) {
                return BYOKConnectionError.modelNotFound
            }
            if http.statusCode == 400 && lower.contains("model") {
                return BYOKConnectionError.modelNotFound
            }
            return BYOKConnectionError.httpFailure(statusCode: http.statusCode, detail: String(detail.prefix(240)))
        }

        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = envelope["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            return BYOKConnectionError.invalidJSON
        }
        let content = (message["content"] as? String) ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return BYOKConnectionError.emptyContent
        }
        do {
            _ = try BYOKProbeValidator.validate(content: content)
            return nil
        } catch {
            return error
        }
    }
}

struct URLSessionHTTPTransport: HTTPTransporting {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func stream(
        for request: URLRequest,
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws -> URLResponse {
        let (bytes, response) = try await session.bytes(for: request)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try await onLine(line)
        }
        return response
    }
}

@MainActor
final class OpenAICompatibleConnectionTester: BYOKConnectionTesting {
    private let transport: any HTTPTransporting

    init(transport: any HTTPTransporting = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    func testConnection(baseURL: String, model: String, apiKey: String) async throws -> String {
        let request = try BYOKConnectionRequestBuilder.makeURLRequest(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw BYOKConnectionError.networkFailure(error.localizedDescription)
        }
        // content(...) already rejects empty/invalid structure via BYOKProbeValidator.
        let content = try BYOKHTTPResponseMapper.content(from: data, response: response)
        let probe = try BYOKProbeValidator.validate(content: content)
        return "连接测试通过：已返回代表性结构化字段（\(probe.title)）"
    }
}
