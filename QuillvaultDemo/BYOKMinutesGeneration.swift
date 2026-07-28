import Foundation

enum MinutesValidationError: LocalizedError, Equatable {
    case emptyContent
    case invalidJSON
    case missingField(String)
    case invalidTimeRange(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            "模型返回空内容"
        case .invalidJSON:
            "模型返回无法解析的 JSON"
        case let .missingField(name):
            "结构化纪要缺少必填字段：\(name)"
        case let .invalidTimeRange(detail):
            "不合法的时间范围：\(detail)"
        case let .generationFailed(detail):
            "纪要生成失败：\(detail)"
        }
    }
}

enum OwnerAttribution {
    static let pendingOwner = "待确认负责人"

    /// Accept owner only when transcript explicitly binds name to responsibility nearby.
    static func resolvedOwner(proposed: String?, transcriptText: String) -> String {
        let name = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return pendingOwner }
        if name == pendingOwner { return pendingOwner }
        guard transcriptText.contains(name) else { return pendingOwner }

        // Explicit local patterns only — global co-occurrence of "完成" elsewhere is insufficient.
        let patterns = [
            "\(name)负责",
            "\(name)跟进",
            "\(name)完成",
            "由\(name)负责",
            "请\(name)负责",
            "\(name) 负责",
            "\(name)来负责"
        ]
        for pattern in patterns where transcriptText.contains(pattern) {
            return name
        }

        // Windowed check: name and responsibility cue within ~12 characters.
        if let nameRange = transcriptText.range(of: name) {
            let start = transcriptText.index(
                nameRange.lowerBound,
                offsetBy: -2,
                limitedBy: transcriptText.startIndex
            ) ?? transcriptText.startIndex
            let end = transcriptText.index(
                nameRange.upperBound,
                offsetBy: 12,
                limitedBy: transcriptText.endIndex
            ) ?? transcriptText.endIndex
            let window = String(transcriptText[start..<end])
            if window.contains("负责") || window.contains("跟进") {
                return name
            }
        }
        return pendingOwner
    }
}

enum StructuredMinutesValidator {
    static func validate(jsonObject: [String: Any], transcriptText: String) throws -> StructuredMinutes {
        func nonEmptyString(_ key: String) throws -> String {
            guard let value = jsonObject[key] as? String else {
                throw MinutesValidationError.missingField(key)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MinutesValidationError.missingField(key) }
            return trimmed
        }

        let title = try nonEmptyString("title")
        let overview = try nonEmptyString("overview")
        let summary = try nonEmptyString("summary")

        guard let chaptersRaw = jsonObject["chapters"] as? [[String: Any]] else {
            throw MinutesValidationError.missingField("chapters")
        }
        guard !chaptersRaw.isEmpty else {
            throw MinutesValidationError.missingField("chapters")
        }
        var chapters: [TopicChapter] = []
        for (index, item) in chaptersRaw.enumerated() {
            guard let cTitle = item["title"] as? String, !cTitle.isEmpty,
                  let cSummary = item["summary"] as? String, !cSummary.isEmpty
            else {
                throw MinutesValidationError.missingField("chapters[\(index)]")
            }
            let start = (item["startTime"] as? Double) ?? (item["startTime"] as? Int).map(Double.init) ?? -1
            let end = (item["endTime"] as? Double) ?? (item["endTime"] as? Int).map(Double.init) ?? -1
            guard start >= 0, end >= start else {
                throw MinutesValidationError.invalidTimeRange("chapters[\(index)] \(start)-\(end)")
            }
            chapters.append(
                TopicChapter(title: cTitle, startTime: start, endTime: end, summary: cSummary)
            )
        }

        let decisionsRaw = jsonObject["decisions"] as? [[String: Any]] ?? []
        var decisions: [DecisionItem] = []
        for (index, item) in decisionsRaw.enumerated() {
            guard let statement = item["statement"] as? String, !statement.isEmpty,
                  let reason = item["reason"] as? String, !reason.isEmpty,
                  let evidence = item["evidence"] as? String, !evidence.isEmpty
            else {
                throw MinutesValidationError.missingField("decisions[\(index)]")
            }
            decisions.append(DecisionItem(statement: statement, reason: reason, evidence: evidence))
        }

        let actionsRaw = jsonObject["actionItems"] as? [[String: Any]] ?? []
        var actionItems: [ActionItem] = []
        for (index, item) in actionsRaw.enumerated() {
            guard let task = item["task"] as? String, !task.isEmpty,
                  let evidence = item["evidence"] as? String, !evidence.isEmpty
            else {
                throw MinutesValidationError.missingField("actionItems[\(index)]")
            }
            let proposedOwner = item["owner"] as? String
            let owner = OwnerAttribution.resolvedOwner(proposed: proposedOwner, transcriptText: transcriptText)
            let deadline = (item["deadline"] as? String) ?? ""
            actionItems.append(
                ActionItem(task: task, owner: owner, deadline: deadline, evidence: evidence)
            )
        }

        let risks = (jsonObject["risks"] as? [String]) ?? []
        let unresolved = (jsonObject["unresolvedQuestions"] as? [String]) ?? []

        guard let graph = jsonObject["coreViewpointGraph"] as? [String: Any] else {
            throw MinutesValidationError.missingField("coreViewpointGraph")
        }
        let nodesRaw = graph["nodes"] as? [[String: Any]] ?? []
        let edgesRaw = graph["edges"] as? [[String: Any]] ?? []
        guard !nodesRaw.isEmpty else {
            throw MinutesValidationError.missingField("coreViewpointGraph.nodes")
        }
        let nodes: [GraphNode] = try nodesRaw.map { node in
            guard let id = node["id"] as? String, !id.isEmpty,
                  let label = node["label"] as? String, !label.isEmpty
            else {
                throw MinutesValidationError.missingField("coreViewpointGraph.nodes")
            }
            return GraphNode(id: id, label: label)
        }
        let edges: [GraphEdge] = edgesRaw.compactMap { edge in
            guard let from = edge["from"] as? String, let to = edge["to"] as? String else { return nil }
            let label = (edge["label"] as? String) ?? ""
            return GraphEdge(from: from, to: to, label: label)
        }

        let sourceLinks = (jsonObject["sourceLinks"] as? [String]) ?? [
            "./transcript.md",
            "./recording.m4a"
        ]

        return StructuredMinutes(
            title: title,
            overview: overview,
            summary: summary,
            chapters: chapters,
            decisions: decisions,
            actionItems: actionItems,
            risks: risks,
            unresolvedQuestions: unresolved,
            coreViewpointGraph: CoreViewpointGraph(nodes: nodes, edges: edges),
            sourceLinks: sourceLinks
        )
    }

    static func validate(content: String, transcriptText: String) throws -> StructuredMinutes {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MinutesValidationError.emptyContent }
        guard let data = trimmed.data(using: .utf8) else { throw MinutesValidationError.invalidJSON }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MinutesValidationError.invalidJSON
        }
        guard let dict = object as? [String: Any] else {
            throw MinutesValidationError.invalidJSON
        }
        return try validate(jsonObject: dict, transcriptText: transcriptText)
    }
}

enum BYOKMinutesRequestBuilder {
    static func makeTranscriptOnlyBody(
        model: String,
        transcript: Transcript
    ) throws -> Data {
        let transcriptText = transcript.segments
            .map { String(format: "[%.1f-%.1f] %@", $0.startTime, $0.endTime, $0.text) }
            .joined(separator: "\n")

        let schemaHint = """
        仅根据逐字稿返回 JSON（不要 Markdown）。字段：
        title, overview, summary,
        chapters:[{title,startTime,endTime,summary}],
        decisions:[{statement,reason,evidence}],
        actionItems:[{task,owner,deadline,evidence}],
        risks:[string], unresolvedQuestions:[string],
        coreViewpointGraph:{nodes:[{id,label}],edges:[{from,to,label}]},
        sourceLinks:[string]
        负责人仅在原文明确姓名与责任关系时填写，否则 owner 必须是「待确认负责人」。
        不要编造原文没有的信息。
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": schemaHint],
                ["role": "user", "content": "逐字稿：\n\(transcriptText)"]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func containsAudioPayload(_ body: Data) -> Bool {
        let text = String(data: body, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("recording.m4a") { return true }
        if text.contains("data:audio") { return true }
        if text.contains("\"audio\"") { return true }
        if text.contains("input_audio") { return true }
        if text.contains("file://") { return true }
        return false
    }
}

@MainActor
final class ControllableMinutesGenerator: MinutesGenerating, BYOKRequestInspecting {
    private var remainingFailures: Int
    private let successMinutes: StructuredMinutes
    private(set) var lastRequestBodyJSON: String?
    private(set) var invokeCount = 0
    var forceInvalidJSON = false

    init(failTimes: Int = 0, successMinutes: StructuredMinutes? = nil) {
        self.remainingFailures = failTimes
        self.successMinutes = successMinutes ?? StructuredMinutes(
            title: "可控纪要",
            overview: "概览",
            summary: "摘要",
            chapters: [
                TopicChapter(title: "开场", startTime: 0, endTime: 3, summary: "讨论开场")
            ],
            decisions: [
                DecisionItem(
                    statement: "采用 MeetingWorkflow",
                    reason: "统一测试切面",
                    evidence: "我们需要验证会议工作流。"
                )
            ],
            actionItems: [
                ActionItem(
                    task: "完成真机测试",
                    owner: "小林",
                    deadline: "周五",
                    evidence: "小林负责完成真机测试，周五前反馈。"
                )
            ],
            risks: ["风险"],
            unresolvedQuestions: ["问题"],
            coreViewpointGraph: CoreViewpointGraph(
                nodes: [GraphNode(id: "a", label: "A"), GraphNode(id: "b", label: "B")],
                edges: [GraphEdge(from: "a", to: "b", label: "需要")]
            ),
            sourceLinks: ["./transcript.md", "./recording.m4a"]
        )
    }

    func generate(from transcript: Transcript) async throws -> StructuredMinutes {
        invokeCount += 1
        let body = try BYOKMinutesRequestBuilder.makeTranscriptOnlyBody(
            model: "deepseek-v4-pro",
            transcript: transcript
        )
        lastRequestBodyJSON = String(data: body, encoding: .utf8)
        if BYOKMinutesRequestBuilder.containsAudioPayload(body) {
            throw MinutesValidationError.generationFailed("privacy violation: audio in body")
        }
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw MinutesValidationError.emptyContent
        }
        if forceInvalidJSON {
            throw MinutesValidationError.invalidJSON
        }
        // Re-validate owner against transcript for realism.
        let transcriptText = transcript.segments.map(\.text).joined(separator: "\n")
        let adjusted = successMinutes.actionItems.map { item in
            ActionItem(
                task: item.task,
                owner: OwnerAttribution.resolvedOwner(proposed: item.owner, transcriptText: transcriptText),
                deadline: item.deadline,
                evidence: item.evidence
            )
        }
        return StructuredMinutes(
            title: successMinutes.title,
            overview: successMinutes.overview,
            summary: successMinutes.summary,
            chapters: successMinutes.chapters,
            decisions: successMinutes.decisions,
            actionItems: adjusted,
            risks: successMinutes.risks,
            unresolvedQuestions: successMinutes.unresolvedQuestions,
            coreViewpointGraph: successMinutes.coreViewpointGraph,
            sourceLinks: successMinutes.sourceLinks
        )
    }
}

@MainActor
final class DeepSeekMinutesGenerator: MinutesGenerating, BYOKRequestInspecting {
    private let apiKeyStore: any APIKeyStoring
    private let preferences: any BYOKPreferencesStoring
    private let transport: any HTTPTransporting
    private(set) var lastRequestBodyJSON: String?

    init(
        apiKeyStore: any APIKeyStoring,
        preferences: any BYOKPreferencesStoring,
        transport: any HTTPTransporting = URLSessionHTTPTransport()
    ) {
        self.apiKeyStore = apiKeyStore
        self.preferences = preferences
        self.transport = transport
    }

    func generate(from transcript: Transcript) async throws -> StructuredMinutes {
        guard let apiKey = try apiKeyStore.load(), !apiKey.isEmpty else {
            throw BYOKConnectionError.missingAPIKey
        }
        let body = try BYOKMinutesRequestBuilder.makeTranscriptOnlyBody(
            model: preferences.model,
            transcript: transcript
        )
        lastRequestBodyJSON = String(data: body, encoding: .utf8)
        if BYOKMinutesRequestBuilder.containsAudioPayload(body) {
            throw MinutesValidationError.generationFailed("请求体不得包含音频载荷")
        }

        var request = try BYOKConnectionRequestBuilder.makeURLRequest(
            baseURL: preferences.baseURL,
            model: preferences.model,
            apiKey: apiKey
        )
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw MinutesValidationError.generationFailed(error.localizedDescription)
        }
        let content = try BYOKHTTPResponseMapper.content(from: data, response: response)
        let transcriptText = transcript.segments.map(\.text).joined(separator: "\n")
        return try StructuredMinutesValidator.validate(content: content, transcriptText: transcriptText)
    }
}
