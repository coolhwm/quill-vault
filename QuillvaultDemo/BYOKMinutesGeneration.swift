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
    static func validate(
        jsonObject: [String: Any],
        transcriptText: String,
        timelineBounds: ClosedRange<TimeInterval>? = nil
    ) throws -> StructuredMinutes {
        func trimmedString(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let suppliedTitle = trimmedString(jsonObject["title"])
        let suppliedOverview = trimmedString(jsonObject["overview"])
        let suppliedSummary = trimmedString(jsonObject["summary"])
        guard let coreText = suppliedSummary ?? suppliedOverview ?? suppliedTitle else {
            throw MinutesValidationError.missingField("summary")
        }
        let title = suppliedTitle ?? "会议纪要"
        let overview = suppliedOverview ?? coreText
        let summary = suppliedSummary ?? coreText

        func finiteTime(_ value: Any?) -> TimeInterval? {
            let time: TimeInterval?
            if let value = value as? Double {
                time = value
            } else if let value = value as? Int {
                time = Double(value)
            } else {
                time = nil
            }
            guard let time, time.isFinite else { return nil }
            return time
        }

        struct ChapterCandidate {
            let title: String
            let start: TimeInterval
            let end: TimeInterval
            let summary: String
        }

        let chaptersRaw = jsonObject["chapters"] as? [[String: Any]] ?? []
        let candidates = chaptersRaw.enumerated().compactMap { index, item -> ChapterCandidate? in
            guard let rawStart = finiteTime(item["startTime"]),
                  let rawEnd = finiteTime(item["endTime"])
            else {
                return nil
            }
            let chapterTitle = trimmedString(item["title"]) ?? "章节 \(index + 1)"
            let chapterSummary = trimmedString(item["summary"]) ?? summary
            return ChapterCandidate(
                title: chapterTitle,
                start: rawStart,
                end: rawEnd,
                summary: chapterSummary
            )
        }
        .sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        var chapters: [TopicChapter] = []
        var previousChapterEnd: TimeInterval?
        for candidate in candidates {
            var start = candidate.start
            var end = candidate.end
            if let timelineBounds {
                start = min(max(start, timelineBounds.lowerBound), timelineBounds.upperBound)
                end = min(max(end, timelineBounds.lowerBound), timelineBounds.upperBound)
            }
            if let previousChapterEnd {
                start = max(start, previousChapterEnd)
            }
            guard start >= 0, end > start else { continue }
            chapters.append(
                TopicChapter(
                    title: candidate.title,
                    startTime: start,
                    endTime: end,
                    summary: candidate.summary
                )
            )
            previousChapterEnd = end
        }
        if chapters.isEmpty {
            let fallbackStart = max(0, timelineBounds?.lowerBound ?? 0)
            let requestedEnd = timelineBounds?.upperBound ?? max(fallbackStart + 1, 1)
            let fallbackEnd = max(requestedEnd, fallbackStart + 0.001)
            chapters = [
                TopicChapter(
                    title: title,
                    startTime: fallbackStart,
                    endTime: fallbackEnd,
                    summary: summary
                )
            ]
        }

        let decisionsRaw = jsonObject["decisions"] as? [[String: Any]] ?? []
        let decisions = decisionsRaw.compactMap { item -> DecisionItem? in
            guard let statement = trimmedString(item["statement"]) else { return nil }
            return DecisionItem(
                statement: statement,
                reason: trimmedString(item["reason"]) ?? "",
                evidence: trimmedString(item["evidence"]) ?? ""
            )
        }

        let actionsRaw = jsonObject["actionItems"] as? [[String: Any]] ?? []
        let actionItems = actionsRaw.compactMap { item -> ActionItem? in
            guard let task = trimmedString(item["task"]) else { return nil }
            let proposedOwner = trimmedString(item["owner"])
            let owner = OwnerAttribution.resolvedOwner(proposed: proposedOwner, transcriptText: transcriptText)
            return ActionItem(
                task: task,
                owner: owner,
                deadline: trimmedString(item["deadline"]) ?? "",
                evidence: trimmedString(item["evidence"]) ?? ""
            )
        }

        let risks = ((jsonObject["risks"] as? [Any]) ?? []).compactMap(trimmedString)
        let unresolved = ((jsonObject["unresolvedQuestions"] as? [Any]) ?? []).compactMap(trimmedString)

        let graph = jsonObject["coreViewpointGraph"] as? [String: Any] ?? [:]
        let nodesRaw = graph["nodes"] as? [[String: Any]] ?? []
        let edgesRaw = graph["edges"] as? [[String: Any]] ?? []
        var seenNodeIDs = Set<String>()
        var nodes = nodesRaw.compactMap { node -> GraphNode? in
            guard let id = trimmedString(node["id"]),
                  let label = trimmedString(node["label"]),
                  seenNodeIDs.insert(id).inserted
            else {
                return nil
            }
            return GraphNode(id: id, label: label)
        }
        if nodes.isEmpty {
            nodes = [GraphNode(id: "summary", label: title)]
        }
        let nodeIDs = Set(nodes.map(\.id))
        let edges = edgesRaw.compactMap { edge -> GraphEdge? in
            guard let from = trimmedString(edge["from"]),
                  let to = trimmedString(edge["to"]),
                  nodeIDs.contains(from),
                  nodeIDs.contains(to)
            else {
                return nil
            }
            return GraphEdge(from: from, to: to, label: trimmedString(edge["label"]) ?? "")
        }

        let sourceLinks = [
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

    static func validate(
        content: String,
        transcriptText: String,
        timelineBounds: ClosedRange<TimeInterval>? = nil
    ) throws -> StructuredMinutes {
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
        return try validate(
            jsonObject: dict,
            transcriptText: transcriptText,
            timelineBounds: timelineBounds
        )
    }
}

enum BYOKMinutesRequestBuilder {
    static func makeTranscriptOnlyBody(
        model: String,
        transcript: Transcript,
        validationFeedback: String? = nil
    ) throws -> Data {
        let transcriptText = transcript.segments
            .map { String(format: "[%.1f-%.1f] %@", $0.startTime, $0.endTime, $0.text) }
            .joined(separator: "\n")
        let firstStart = transcript.segments.map(\.startTime).min() ?? 0
        let lastEnd = transcript.segments.map(\.endTime).max() ?? 0
        let feedbackHint = validationFeedback.map {
            "\n上一次输出被校验器拒绝：\($0)。必须修正该错误后重新生成完整 JSON。"
        } ?? ""

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
        chapters 必须至少包含一项；每项 startTime/endTime 必须是数字，且满足 \
        \(String(format: "%.1f", firstStart)) <= startTime < endTime <= \
        \(String(format: "%.1f", lastEnd))。严禁使用 -1、null 或占位时间；时间必须从逐字稿方括号中的实际范围取值。
        chapters 按时间升序排列且不得重叠。sourceLinks 只填写 "./transcript.md"。
        coreViewpointGraph.nodes 必须至少包含一个 {id,label} 节点；即使只有一个主题也不能返回空数组。
        coreViewpointGraph.edges 可以为空；但每条边的 from/to 必须引用 nodes 中真实存在的 id。
        title、overview、summary、每个 chapter 的 title/summary 均必须是非空字符串。
        \(feedbackHint)
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": schemaHint],
                ["role": "user", "content": "逐字稿：\n\(transcriptText)"]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "stream": true
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

    func generate(
        from transcript: Transcript,
        onProgress: (@MainActor @Sendable (MinutesGenerationProgress) -> Void)?
    ) async throws -> StructuredMinutes {
        invokeCount += 1
        onProgress?(
            MinutesGenerationProgress(
                message: "可控纪要生成中",
                completedSteps: 0,
                totalSteps: 1,
                receivedCharacters: 0
            )
        )
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
        let minutes = StructuredMinutes(
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
        onProgress?(
            MinutesGenerationProgress(
                message: "可控纪要生成完成",
                completedSteps: 1,
                totalSteps: 1,
                receivedCharacters: lastRequestBodyJSON?.count ?? 0
            )
        )
        return minutes
    }
}

enum LongTranscriptPlanner {
    static let maximumChunkDuration: TimeInterval = 10 * 60
    static let maximumChunkCharacters = 5_000

    static func chunks(for transcript: Transcript) -> [Transcript] {
        let segments = transcript.segments.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        guard !segments.isEmpty else { return [transcript] }

        var result: [Transcript] = []
        var current: [TranscriptSegment] = []
        var characterCount = 0
        var chunkStart = segments[0].startTime

        for segment in segments {
            let exceedsDuration = segment.endTime - chunkStart > maximumChunkDuration
            let exceedsCharacters = characterCount + segment.text.count > maximumChunkCharacters
            if !current.isEmpty, exceedsDuration || exceedsCharacters {
                result.append(Transcript(segments: current))
                current = []
                characterCount = 0
                chunkStart = segment.startTime
            }
            current.append(segment)
            characterCount += segment.text.count
        }
        if !current.isEmpty {
            result.append(Transcript(segments: current))
        }
        return result
    }

    static func condensedTranscript(
        chunks: [Transcript],
        minutes: [StructuredMinutes]
    ) -> Transcript {
        let segments = zip(chunks, minutes).compactMap { chunk, item -> TranscriptSegment? in
            guard let start = chunk.segments.first?.startTime,
                  let end = chunk.segments.last?.endTime
            else { return nil }
            let chapters = item.chapters.map {
                "\($0.title)(\(String(format: "%.1f", $0.startTime))-\(String(format: "%.1f", $0.endTime))): \($0.summary)"
            }.joined(separator: "；")
            let decisions = item.decisions.map(\.statement).joined(separator: "；")
            let actions = item.actionItems.map {
                "\($0.task) / \($0.owner) / \($0.deadline)"
            }.joined(separator: "；")
            let text = """
            分块标题：\(item.title)
            分块概览：\(item.overview)
            分块摘要：\(item.summary)
            章节：\(chapters)
            决策：\(decisions)
            待办：\(actions)
            风险：\(item.risks.joined(separator: "；"))
            未决问题：\(item.unresolvedQuestions.joined(separator: "；"))
            """
            return TranscriptSegment(
                startTime: start,
                endTime: end,
                text: text,
                isFinal: true
            )
        }
        return Transcript(segments: segments)
    }
}

private struct StreamConsumption: Sendable {
    let receivedCharacters: Int
    let shouldReport: Bool
}

private actor OpenAICompatibleSSEAccumulator {
    private var content = ""
    private var rawLines: [String] = []
    private var lastReportedCharacters = 0
    private var receivedDone = false

    func consume(_ line: String) throws -> StreamConsumption {
        rawLines.append(line)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return StreamConsumption(receivedCharacters: content.count, shouldReport: false)
        }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            receivedDone = true
            return StreamConsumption(receivedCharacters: content.count, shouldReport: true)
        }
        guard let data = payload.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BYOKConnectionError.invalidJSON
        }
        if let error = envelope["error"] as? [String: Any] {
            let detail = (error["message"] as? String) ?? String(payload.prefix(240))
            throw BYOKConnectionError.httpFailure(statusCode: 200, detail: detail)
        }
        let choices = envelope["choices"] as? [[String: Any]]
        let delta = choices?.first?["delta"] as? [String: Any]
        if let fragment = delta?["content"] as? String {
            content += fragment
        }
        let shouldReport = content.count - lastReportedCharacters >= 128
        if shouldReport {
            lastReportedCharacters = content.count
        }
        return StreamConsumption(
            receivedCharacters: content.count,
            shouldReport: shouldReport
        )
    }

    func finalContent(response: URLResponse) throws -> String {
        let rawBody = rawLines.joined(separator: "\n")
        let data = Data(rawBody.utf8)
        guard let http = response as? HTTPURLResponse else {
            throw BYOKConnectionError.networkFailure("非 HTTP 响应")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw BYOKHTTPResponseMapper.map(data: data, response: response)
                ?? BYOKConnectionError.httpFailure(
                    statusCode: http.statusCode,
                    detail: String(rawBody.prefix(240))
                )
        }
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        // Compatibility path for OpenAI-compatible providers or test transports that
        // ignore stream=true and return one ordinary JSON envelope.
        if !rawBody.isEmpty {
            return try BYOKHTTPResponseMapper.content(from: data, response: response)
        }
        if receivedDone {
            throw BYOKConnectionError.emptyContent
        }
        throw BYOKConnectionError.emptyContent
    }
}

@MainActor
final class DeepSeekMinutesGenerator: MinutesGenerating, BYOKRequestInspecting {
    private let apiKeyStore: any APIKeyStoring
    private let preferences: any BYOKPreferencesStoring
    private let transport: any HTTPTransporting
    private(set) var lastRequestBodyJSON: String?
    private var validationFeedbackByStage: [String: String] = [:]

    init(
        apiKeyStore: any APIKeyStoring,
        preferences: any BYOKPreferencesStoring,
        transport: any HTTPTransporting = URLSessionHTTPTransport()
    ) {
        self.apiKeyStore = apiKeyStore
        self.preferences = preferences
        self.transport = transport
    }

    func generate(
        from transcript: Transcript,
        onProgress: (@MainActor @Sendable (MinutesGenerationProgress) -> Void)?
    ) async throws -> StructuredMinutes {
        guard let apiKey = try apiKeyStore.load(), !apiKey.isEmpty else {
            throw BYOKConnectionError.missingAPIKey
        }
        let chunks = LongTranscriptPlanner.chunks(for: transcript)
        if chunks.count == 1 {
            return try await generateOne(
                from: transcript,
                apiKey: apiKey,
                stageID: "single",
                progressLabel: "正在接收结构化纪要",
                completedSteps: 0,
                totalSteps: 1,
                onProgress: onProgress
            )
        }

        let totalSteps = chunks.count + 1
        var chunkMinutes: [StructuredMinutes] = []
        chunkMinutes.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            let minutes = try await generateOne(
                from: chunk,
                apiKey: apiKey,
                stageID: "chunk-\(index)",
                progressLabel: "正在摘要第 \(index + 1)/\(chunks.count) 段",
                completedSteps: index,
                totalSteps: totalSteps,
                onProgress: onProgress
            )
            chunkMinutes.append(minutes)
        }

        let condensed = LongTranscriptPlanner.condensedTranscript(
            chunks: chunks,
            minutes: chunkMinutes
        )
        return try await generateOne(
            from: condensed,
            apiKey: apiKey,
            stageID: "synthesis",
            progressLabel: "正在合并长会议纪要",
            completedSteps: chunks.count,
            totalSteps: totalSteps,
            onProgress: onProgress
        )
    }

    private func generateOne(
        from transcript: Transcript,
        apiKey: String,
        stageID: String,
        progressLabel: String,
        completedSteps: Int,
        totalSteps: Int,
        onProgress: (@MainActor @Sendable (MinutesGenerationProgress) -> Void)?
    ) async throws -> StructuredMinutes {
        let body = try BYOKMinutesRequestBuilder.makeTranscriptOnlyBody(
            model: preferences.model,
            transcript: transcript,
            validationFeedback: validationFeedbackByStage[stageID]
        )
        lastRequestBodyJSON = String(data: body, encoding: .utf8)
        if BYOKMinutesRequestBuilder.containsAudioPayload(body) {
            throw MinutesValidationError.generationFailed("请求体不得包含音频载荷")
        }

        var request = try BYOKConnectionRequestBuilder.makeURLRequest(
            baseURL: preferences.baseURL,
            model: preferences.model,
            apiKey: apiKey,
            purpose: .minutesGeneration
        )
        request.httpBody = body

        onProgress?(
            MinutesGenerationProgress(
                message: "\(progressLabel)…",
                completedSteps: completedSteps,
                totalSteps: totalSteps,
                receivedCharacters: 0
            )
        )
        let accumulator = OpenAICompatibleSSEAccumulator()
        let response: URLResponse
        do {
            response = try await transport.stream(for: request) { line in
                let update = try await accumulator.consume(line)
                if update.shouldReport {
                    await onProgress?(
                        MinutesGenerationProgress(
                            message: "\(progressLabel)，已接收 \(update.receivedCharacters) 字",
                            completedSteps: completedSteps,
                            totalSteps: totalSteps,
                            receivedCharacters: update.receivedCharacters
                        )
                    )
                }
            }
        } catch let error as URLError where error.code == .timedOut {
            throw MinutesValidationError.generationFailed(
                "模型响应超时（首段等待上限 90 秒，单次生成整体上限 5 分钟）"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MinutesValidationError.generationFailed(error.localizedDescription)
        }
        let content = try await accumulator.finalContent(response: response)
        let transcriptText = transcript.segments.map(\.text).joined(separator: "\n")
        let starts = transcript.segments.map(\.startTime)
        let ends = transcript.segments.map(\.endTime)
        let timelineBounds: ClosedRange<TimeInterval>?
        if let minimumStart = starts.min(), let maximumEnd = ends.max() {
            timelineBounds = minimumStart ... maximumEnd
        } else {
            timelineBounds = nil
        }
        do {
            let minutes = try StructuredMinutesValidator.validate(
                content: content,
                transcriptText: transcriptText,
                timelineBounds: timelineBounds
            )
            validationFeedbackByStage[stageID] = nil
            onProgress?(
                MinutesGenerationProgress(
                    message: "\(progressLabel)完成",
                    completedSteps: completedSteps + 1,
                    totalSteps: totalSteps,
                    receivedCharacters: content.count
                )
            )
            return minutes
        } catch let error as MinutesValidationError {
            validationFeedbackByStage[stageID] = error.localizedDescription
            throw error
        }
    }
}
