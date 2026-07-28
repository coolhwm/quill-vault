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

    func testInvalidTimeRangeRejected() {
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
        XCTAssertThrowsError(
            try StructuredMinutesValidator.validate(content: json, transcriptText: "x")
        ) { error in
            guard case let .invalidTimeRange(detail) = error as? MinutesValidationError else {
                return XCTFail("Expected invalidTimeRange, got \(error)")
            }
            XCTAssertTrue(detail.contains("chapters[0]"))
        }
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
        writer: ControllableAssetWriter = ControllableAssetWriter()
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
            transcriber: ControllableTranscriber(
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
}
