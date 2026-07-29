import XCTest
@testable import QuillvaultDemo

@MainActor
final class BYOKMinutesTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillvaultMinutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSuccessfulBYOKGenerationAfterFinalTranscript() async {
        let generator = ControllableMinutesGenerator(failTimes: 0)
        let writer = ControllableAssetWriter()
        let workflow = MeetingWorkflow(dependencies: makeDeps(generator: generator, writer: writer))

        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()

        guard case let .completed(assets) = workflow.state else {
            return XCTFail("Expected completed")
        }
        XCTAssertEqual(assets.minutes.title, "可控纪要")
        XCTAssertFalse(assets.minutes.chapters.isEmpty)
        XCTAssertFalse(assets.minutes.decisions.isEmpty)
        XCTAssertEqual(generator.invokeCount, 1)
        XCTAssertTrue(writer.lastWroteMinutes)
        XCTAssertTrue(assets.files.map(\.name).contains("minutes.md"))
    }

    func testOneRetryThenSuccess() async {
        let generator = ControllableMinutesGenerator(failTimes: 1)
        let workflow = MeetingWorkflow(dependencies: makeDeps(generator: generator))

        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()

        XCTAssertEqual(workflow.phase, .completed)
        XCTAssertEqual(generator.invokeCount, 2)
    }

    func testRetryExhaustionPreservesSourceAndSkipsMinutes() async {
        let generator = ControllableMinutesGenerator(failTimes: 2)
        let writer = ControllableAssetWriter()
        let workflow = MeetingWorkflow(dependencies: makeDeps(generator: generator, writer: writer))

        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()

        guard case let .failed(message) = workflow.state else {
            return XCTFail("Expected failed after retry exhaustion")
        }
        XCTAssertTrue(message.contains("minutes.md") || message.contains("重试") || message.contains("保留"))
        XCTAssertEqual(generator.invokeCount, 2)
        XCTAssertGreaterThanOrEqual(writer.writeCallCount, 1)
        XCTAssertFalse(writer.lastWroteMinutes)
        XCTAssertNotNil(workflow.preservedRecordingURL)
        // Source files written without minutes
        let meetingDir = tempRoot.appendingPathComponent("vault/meeting-test", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingDir.appendingPathComponent("transcript.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingDir.appendingPathComponent("minutes.md").path))
    }

    func testRequestBodyContainsOnlyTranscriptTextNoAudio() async throws {
        let generator = ControllableMinutesGenerator(failTimes: 0)
        let workflow = MeetingWorkflow(dependencies: makeDeps(generator: generator))
        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()

        let body = try XCTUnwrap(generator.lastRequestBodyJSON)
        XCTAssertTrue(body.contains("逐字稿") || body.contains("["))
        XCTAssertFalse(BYOKMinutesRequestBuilder.containsAudioPayload(Data(body.utf8)))
        XCTAssertFalse(body.lowercased().contains("recording.m4a"))
        XCTAssertFalse(body.lowercased().contains("input_audio"))
        XCTAssertFalse(body.contains("data:audio"))
    }

    func testRequestPromptConstrainsChapterTimesAndIncludesRetryFeedback() throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(startTime: 0.2, endTime: 7.0, text: "开场", isFinal: true),
            TranscriptSegment(startTime: 7.2, endTime: 40.2, text: "后台录音验证", isFinal: true)
        ])

        let body = try BYOKMinutesRequestBuilder.makeTranscriptOnlyBody(
            model: "deepseek-v4-pro",
            transcript: transcript,
            validationFeedback: "不合法的时间范围：chapters[0] -1.0–-1.0"
        )
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(text.contains("0.2 <= startTime < endTime <= 40.2"))
        XCTAssertTrue(text.contains("严禁使用 -1"))
        XCTAssertTrue(text.contains("coreViewpointGraph.nodes 必须至少包含一个"))
        XCTAssertTrue(text.contains("上一次输出被校验器拒绝"))
        XCTAssertTrue(text.contains("chapters[0] -1.0"))
    }

    func testGenerationRequestIsStreamingAndNotLimitedByProbeTimeout() throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(startTime: 0, endTime: 2_740.9, text: "长会议逐字稿", isFinal: true)
        ])
        let body = try BYOKMinutesRequestBuilder.makeTranscriptOnlyBody(
            model: "deepseek-v4-pro",
            transcript: transcript
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["stream"] as? Bool, true)

        let request = try BYOKConnectionRequestBuilder.makeURLRequest(
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "sk-demo",
            purpose: .minutesGeneration
        )
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 90)
    }

    func testStreamingGeneratorAccumulatesSSEAndReportsProgress() async throws {
        let content = Self.validMinutesJSON
        let midpoint = content.index(content.startIndex, offsetBy: content.count / 2)
        let transport = ScriptedStreamingTransport(
            fragments: [
                String(content[..<midpoint]),
                String(content[midpoint...])
            ]
        )
        let generator = DeepSeekMinutesGenerator(
            apiKeyStore: InMemoryAPIKeyStore(initial: "sk-test"),
            preferences: InMemoryBYOKPreferences(),
            transport: transport
        )
        let transcript = Transcript(segments: [
            TranscriptSegment(startTime: 0, endTime: 8, text: "测试流式纪要", isFinal: true)
        ])
        var progress: [MinutesGenerationProgress] = []

        let minutes = try await generator.generate(from: transcript) {
            progress.append($0)
        }

        XCTAssertEqual(minutes.title, "流式纪要")
        XCTAssertTrue(progress.contains { $0.receivedCharacters > 0 })
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.timeoutInterval, 90)
        let requestBody = try XCTUnwrap(request.httpBody)
        let requestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(requestJSON["stream"] as? Bool, true)
    }

    func testLongTranscriptUsesChunkSummariesThenFinalSynthesis() async throws {
        let segments = (0 ..< 46).map { index in
            TranscriptSegment(
                startTime: Double(index * 60),
                endTime: Double((index + 1) * 60),
                text: "第 \(index + 1) 分钟的会议内容",
                isFinal: true
            )
        }
        let transcript = Transcript(segments: segments)
        let chunks = LongTranscriptPlanner.chunks(for: transcript)
        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy {
            guard let first = $0.segments.first, let last = $0.segments.last else { return false }
            return last.endTime - first.startTime <= LongTranscriptPlanner.maximumChunkDuration
        })

        let transport = ScriptedStreamingTransport(
            contentForRequest: makeTimelineBoundMinutesJSON
        )
        let generator = DeepSeekMinutesGenerator(
            apiKeyStore: InMemoryAPIKeyStore(initial: "sk-test"),
            preferences: InMemoryBYOKPreferences(),
            transport: transport
        )
        _ = try await generator.generate(from: transcript)

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, chunks.count + 1)
    }

    func testOwnerRuleUsesPendingWhenNotExplicit() throws {
        let json = """
        {
          "title":"t","overview":"o","summary":"s",
          "chapters":[{"title":"c","startTime":0,"endTime":1,"summary":"cs"}],
          "decisions":[{"statement":"d","reason":"r","evidence":"e"}],
          "actionItems":[{"task":"跟进方案","owner":"张三","deadline":"明天","evidence":"需要跟进方案"}],
          "risks":[],"unresolvedQuestions":[],
          "coreViewpointGraph":{"nodes":[{"id":"a","label":"A"}],"edges":[]},
          "sourceLinks":["./transcript.md"]
        }
        """
        // Transcript never names 张三 with responsibility.
        let minutes = try StructuredMinutesValidator.validate(
            content: json,
            transcriptText: "今天讨论方案，需要跟进。"
        )
        XCTAssertEqual(minutes.actionItems.first?.owner, OwnerAttribution.pendingOwner)
    }

    func testOwnerKeptWhenTranscriptExplicit() throws {
        let json = """
        {
          "title":"t","overview":"o","summary":"s",
          "chapters":[{"title":"c","startTime":0,"endTime":2,"summary":"cs"}],
          "decisions":[{"statement":"d","reason":"r","evidence":"e"}],
          "actionItems":[{"task":"完成真机测试","owner":"小林","deadline":"周五","evidence":"小林负责完成真机测试"}],
          "risks":[],"unresolvedQuestions":[],
          "coreViewpointGraph":{"nodes":[{"id":"a","label":"A"}],"edges":[]},
          "sourceLinks":["./transcript.md"]
        }
        """
        let minutes = try StructuredMinutesValidator.validate(
            content: json,
            transcriptText: "小林负责完成真机测试，周五前反馈。"
        )
        XCTAssertEqual(minutes.actionItems.first?.owner, "小林")
    }

    func testInvalidTimeRangeFallsBackToDisplayableChapter() throws {
        let json = """
        {
          "title":"t","overview":"o","summary":"s",
          "chapters":[{"title":"c","startTime":5,"endTime":1,"summary":"cs"}],
          "decisions":[{"statement":"d","reason":"r","evidence":"e"}],
          "actionItems":[],
          "risks":[],"unresolvedQuestions":[],
          "coreViewpointGraph":{"nodes":[{"id":"a","label":"A"}],"edges":[]},
          "sourceLinks":[]
        }
        """
        let minutes = try StructuredMinutesValidator.validate(content: json, transcriptText: "x")
        XCTAssertEqual(minutes.chapters.count, 1)
        XCTAssertEqual(minutes.chapters[0].startTime, 0)
        XCTAssertEqual(minutes.chapters[0].endTime, 1)
        XCTAssertEqual(minutes.chapters[0].summary, "s")
    }

    func testValidatorClampsModelRoundedEndToExactTranscriptBoundary() throws {
        let json = """
        {
          "title":"t","overview":"o","summary":"s",
          "chapters":[{"title":"c","startTime":296.3,"endTime":302.8,"summary":"cs"}],
          "decisions":[],"actionItems":[],"risks":[],"unresolvedQuestions":[],
          "coreViewpointGraph":{"nodes":[{"id":"a","label":"A"}],"edges":[]},
          "sourceLinks":["./transcript.md"]
        }
        """

        let minutes = try StructuredMinutesValidator.validate(
            content: json,
            transcriptText: "x",
            timelineBounds: 6.0 ... 302.7971875
        )

        let chapterEnd = try XCTUnwrap(minutes.chapters.last?.endTime)
        XCTAssertEqual(chapterEnd, 302.7971875, accuracy: 0.000_001)
    }

    func testValidatorBuildsDisplayableFallbacksForRecoverableModelShape() throws {
        let json = """
        {
          "summary":"仍然可以展示的会议摘要",
          "chapters":[],
          "decisions":[{"statement":"保留正文"}],
          "actionItems":[{"task":"继续验证"}],
          "coreViewpointGraph":{"nodes":[],"edges":[{"from":"x","to":"y"}]},
          "sourceLinks":["https://invalid.example/transcript"]
        }
        """

        let minutes = try StructuredMinutesValidator.validate(
            content: json,
            transcriptText: "继续验证",
            timelineBounds: 0 ... 10
        )

        XCTAssertEqual(minutes.title, "会议纪要")
        XCTAssertEqual(minutes.overview, "仍然可以展示的会议摘要")
        XCTAssertEqual(minutes.chapters.count, 1)
        XCTAssertEqual(minutes.coreViewpointGraph.nodes.count, 1)
        XCTAssertTrue(minutes.coreViewpointGraph.edges.isEmpty)
        XCTAssertEqual(minutes.sourceLinks, ["./transcript.md", "./recording.m4a"])
    }

    func testValidatorRepairsOutOfBoundsOverlapDanglingEdgesAndAbsoluteLinks() throws {
        let base: [String: Any] = [
            "title": "t", "overview": "o", "summary": "s",
            "chapters": [
                ["title": "c", "startTime": 0.0, "endTime": 3.0, "summary": "cs"]
            ],
            "decisions": [], "actionItems": [], "risks": [], "unresolvedQuestions": [],
            "coreViewpointGraph": [
                "nodes": [["id": "a", "label": "A"]],
                "edges": []
            ],
            "sourceLinks": ["./transcript.md"]
        ]

        var outOfBounds = base
        outOfBounds["chapters"] = [
            ["title": "c", "startTime": 0.0, "endTime": 12.0, "summary": "cs"]
        ]
        let clamped = try StructuredMinutesValidator.validate(
            jsonObject: outOfBounds,
            transcriptText: "x",
            timelineBounds: 0 ... 10
        )
        XCTAssertEqual(clamped.chapters[0].endTime, 10)

        var overlapping = base
        overlapping["chapters"] = [
            ["title": "a", "startTime": 0.0, "endTime": 6.0, "summary": "a"],
            ["title": "b", "startTime": 5.0, "endTime": 9.0, "summary": "b"]
        ]
        let normalized = try StructuredMinutesValidator.validate(
            jsonObject: overlapping,
            transcriptText: "x",
            timelineBounds: 0 ... 10
        )
        XCTAssertEqual(normalized.chapters.count, 2)
        XCTAssertEqual(normalized.chapters[1].startTime, 6)

        var danglingEdge = base
        danglingEdge["coreViewpointGraph"] = [
            "nodes": [["id": "a", "label": "A"]],
            "edges": [["from": "a", "to": "missing", "label": "x"]]
        ]
        let repairedGraph = try StructuredMinutesValidator.validate(
            jsonObject: danglingEdge,
            transcriptText: "x",
            timelineBounds: 0 ... 10
        )
        XCTAssertTrue(repairedGraph.coreViewpointGraph.edges.isEmpty)

        var absoluteLink = base
        absoluteLink["sourceLinks"] = ["https://example.com/transcript.md"]
        let repairedLinks = try StructuredMinutesValidator.validate(
            jsonObject: absoluteLink,
            transcriptText: "x",
            timelineBounds: 0 ... 10
        )
        XCTAssertEqual(repairedLinks.sourceLinks, ["./transcript.md", "./recording.m4a"])
    }

    func testExistingMeetingDirectorySkipsTranscriptionAndGeneratesMinutes() async throws {
        let meetingDirectory = tempRoot.appendingPathComponent(
            "archived-session",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: meetingDirectory,
            withIntermediateDirectories: true
        )
        try Data([0x01, 0x02, 0x03]).write(
            to: meetingDirectory.appendingPathComponent("recording.m4a")
        )
        let expectedTranscript = Transcript(segments: [
            TranscriptSegment(
                startTime: 0.2,
                endTime: 4.8,
                text: "复用已有逐字稿验证纪要。",
                isFinal: true
            ),
            TranscriptSegment(
                startTime: 4.8,
                endTime: 9.1,
                text: "不需要重新录音或转写。",
                isFinal: true
            )
        ])
        try FileMeetingAssetWriter.transcriptMarkdown(from: expectedTranscript).write(
            to: meetingDirectory.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )

        let transcriber = ControllableTranscriber()
        transcriber.startError = TranscriptionError.failed("不应启动实时转写")
        transcriber.finalizeError = TranscriptionError.failed("不应重新转写")
        let generator = ControllableMinutesGenerator(failTimes: 0)
        let workflow = MeetingWorkflow(
            dependencies: makeDeps(
                generator: generator,
                writer: FileMeetingAssetWriter(),
                transcriber: transcriber
            )
        )

        await workflow.generateMinutesFromExistingMeetingDirectory(meetingDirectory)

        XCTAssertEqual(workflow.phase, .completed)
        XCTAssertEqual(generator.invokeCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: meetingDirectory.appendingPathComponent("minutes.md").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: meetingDirectory
                    .appendingPathComponent("meeting-test/minutes.md")
                    .path
            )
        )
    }

    func testManualRetryAfterFailure() async {
        let generator = ControllableMinutesGenerator(failTimes: 2)
        let workflow = MeetingWorkflow(dependencies: makeDeps(generator: generator))
        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()
        XCTAssertEqual(workflow.phase, .failed)

        // Next two invokes will succeed (remainingFailures already 0 after two failures).
        await workflow.retryGenerateMinutes()
        XCTAssertEqual(workflow.phase, .completed)
        XCTAssertEqual(generator.invokeCount, 3)
    }

    private func makeDeps(
        generator: ControllableMinutesGenerator,
        writer: any MeetingAssetWriting = ControllableAssetWriter(),
        transcriber: (any Transcribing)? = nil
    ) -> MeetingWorkflowDependencies {
        let keyStore = InMemoryAPIKeyStore(initial: "sk-test")
        let bookmarking = ControllableBookmarking()
        let folder = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = (try? bookmarking.makeBookmark(for: folder)) ?? Data()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: InMemoryBookmarkStore(data: bookmark),
            bookmarking: bookmarking
        )
        let segments = [
            TranscriptSegment(
                startTime: 0,
                endTime: 3.2,
                text: "我们需要验证会议工作流。",
                isFinal: true
            ),
            TranscriptSegment(
                startTime: 3.2,
                endTime: 7.8,
                text: "小林负责完成真机测试，周五前反馈。",
                isFinal: true
            )
        ]
        return MeetingWorkflowDependencies(
            audioRecorder: ControllableAudioRecorder(),
            transcriber: transcriber ?? ControllableTranscriber(
                liveEvents: segments,
                finalTranscript: Transcript(segments: segments)
            ),
            minutesGenerator: generator,
            credentialChecker: StoreBackedCredentialChecker(store: keyStore),
            directoryAccess: access,
            assetWriter: writer,
            mermaidGenerator: DeterministicMermaidGenerator(),
            mermaidRenderer: DemoMermaidRenderer(),
            apiKeyStore: keyStore,
            byokPreferences: InMemoryBYOKPreferences(),
            connectionTester: ControllableDemoConnectionTester(),
            microphonePermission: ControllableMicrophonePermission(granted: true)
        )
    }

    private static let validMinutesJSON = """
    {
      "title":"流式纪要","overview":"概览","summary":"摘要",
      "chapters":[{"title":"章节","startTime":0,"endTime":1,"summary":"章节摘要"}],
      "decisions":[],"actionItems":[],"risks":[],"unresolvedQuestions":[],
      "coreViewpointGraph":{"nodes":[{"id":"n1","label":"核心观点"}],"edges":[]},
      "sourceLinks":["./transcript.md"]
    }
    """
}

private actor ScriptedStreamingTransport: HTTPTransporting {
    private let lineFactory: @Sendable (URLRequest) -> [String]
    private var requests: [URLRequest] = []

    init(fragments: [String]) {
        self.lineFactory = { _ in
            Self.makeLines(fragments: fragments)
        }
    }

    init(contentForRequest: @escaping @Sendable (URLRequest) -> String) {
        self.lineFactory = { request in
            Self.makeLines(fragments: [contentForRequest(request)])
        }
    }

    private static func makeLines(fragments: [String]) -> [String] {
        fragments.map { fragment in
            let envelope: [String: Any] = [
                "choices": [["delta": ["content": fragment]]]
            ]
            let data = try! JSONSerialization.data(withJSONObject: envelope)
            return "data: \(String(data: data, encoding: .utf8)!)"
        } + ["data: [DONE]"]
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.unsupportedURL)
    }

    func stream(
        for request: URLRequest,
        onLine: @escaping @Sendable (String) async throws -> Void
    ) async throws -> URLResponse {
        requests.append(request)
        for line in lineFactory(request) {
            try await onLine(line)
        }
        return HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }

    func requestCount() -> Int {
        requests.count
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}

private func makeTimelineBoundMinutesJSON(for request: URLRequest) -> String {
    guard let body = request.httpBody,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let messages = json["messages"] as? [[String: Any]],
          let userContent = messages.last?["content"] as? String
    else {
        return "{}"
    }
    let expression = try! NSRegularExpression(
        pattern: #"\[(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\]"#
    )
    let range = NSRange(userContent.startIndex..., in: userContent)
    let matches = expression.matches(in: userContent, range: range)
    guard let first = matches.first,
          let last = matches.last,
          let firstRange = Range(first.range(at: 1), in: userContent),
          let lastRange = Range(last.range(at: 2), in: userContent)
    else {
        return "{}"
    }
    let start = userContent[firstRange]
    let end = userContent[lastRange]
    return """
    {
      "title":"流式纪要","overview":"概览","summary":"摘要",
      "chapters":[{"title":"章节","startTime":\(start),"endTime":\(end),"summary":"章节摘要"}],
      "decisions":[],"actionItems":[],"risks":[],"unresolvedQuestions":[],
      "coreViewpointGraph":{"nodes":[{"id":"n1","label":"核心观点"}],"edges":[]},
      "sourceLinks":["./transcript.md"]
    }
    """
}
