import XCTest
@testable import QuillvaultDemo

@MainActor
final class BackgroundCatchUpTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillvaultBG-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAnalysisPausePartialResultsThenCatchUpOnForeground() async {
        let partial = [
            TranscriptSegment(startTime: 0, endTime: 3, text: "前台片段", isFinal: true)
        ]
        let catchUp = [
            TranscriptSegment(startTime: 3, endTime: 8, text: "后台补齐片段", isFinal: true)
        ]
        let transcriber = ControllableTranscriber(
            liveEvents: partial,
            finalTranscript: Transcript(segments: partial + catchUp),
            catchUpSegments: catchUp
        )
        let workflow = MeetingWorkflow(dependencies: makeDeps(transcriber: transcriber))

        await workflow.startFaceToFaceSession()
        XCTAssertEqual(workflow.phase, .recording)
        XCTAssertEqual(workflow.lastCompletedAudioEnd, 3, accuracy: 0.01)

        workflow.handleEnteredBackground()
        XCTAssertTrue(workflow.analysisPaused)
        XCTAssertEqual(transcriber.pausedAt ?? -1, workflow.recordingDuration, accuracy: 1.0)
        XCTAssertNotNil(workflow.diagnosticNote)

        await workflow.handleBecameActive()
        XCTAssertFalse(workflow.analysisPaused)
        XCTAssertEqual(workflow.liveTranscript.map(\.text), ["前台片段", "后台补齐片段"])
        XCTAssertEqual(workflow.lastCompletedAudioEnd, 8, accuracy: 0.01)
        XCTAssertEqual(transcriber.catchUpCalls.count, 1)
    }

    func testStopCatchUpProducesGapFreeTimelineWithoutDuplicates() async {
        let partial = [
            TranscriptSegment(startTime: 0, endTime: 2, text: "A", isFinal: true),
            // intentional near-duplicate from flaky live path
            TranscriptSegment(startTime: 0, endTime: 2, text: "A", isFinal: true)
        ]
        let catchUp = [
            TranscriptSegment(startTime: 2, endTime: 5, text: "B", isFinal: true),
            TranscriptSegment(startTime: 5, endTime: 9, text: "C", isFinal: true)
        ]
        let transcriber = ControllableTranscriber(
            liveEvents: partial,
            finalTranscript: Transcript(segments: [
                TranscriptSegment(startTime: 0, endTime: 2, text: "A", isFinal: true),
                TranscriptSegment(startTime: 2, endTime: 5, text: "B", isFinal: true),
                TranscriptSegment(startTime: 5, endTime: 9, text: "C", isFinal: true)
            ]),
            catchUpSegments: catchUp
        )
        let workflow = MeetingWorkflow(dependencies: makeDeps(transcriber: transcriber))
        await workflow.startFaceToFaceSession()
        workflow.handleEnteredBackground()
        await workflow.finishFaceToFaceSession()

        guard case let .completed(assets) = workflow.state else {
            return XCTFail("Expected completed, got \(workflow.state)")
        }
        let texts = assets.transcript.segments.map(\.text)
        XCTAssertEqual(texts, ["A", "B", "C"])
        XCTAssertTrue(
            TranscriptTimeline.coversRecordingDuration(
                assets.transcript.segments,
                duration: 9
            )
        )
        // catch-up on stop + finalize path should have invoked catch-up
        XCTAssertFalse(transcriber.catchUpCalls.isEmpty)
        XCTAssertNotNil(workflow.preservedRecordingURL)
    }

    func testCatchUpFailureKeepsRecordingAndShowsDiagnostic() async {
        let transcriber = ControllableTranscriber(
            liveEvents: [
                TranscriptSegment(startTime: 0, endTime: 1, text: "ok", isFinal: true)
            ]
        )
        transcriber.catchUpError = TranscriptionError.failed("模拟追平失败")
        let workflow = MeetingWorkflow(dependencies: makeDeps(transcriber: transcriber))

        await workflow.startFaceToFaceSession()
        let recording = workflow.preservedRecordingURL
        workflow.handleEnteredBackground()
        await workflow.handleBecameActive()

        XCTAssertEqual(workflow.phase, .recording)
        XCTAssertEqual(workflow.preservedRecordingURL, recording)
        XCTAssertTrue(workflow.diagnosticNote?.contains("追平失败") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording!.path))
    }

    func testTimelineMergerRemovesDuplicatesAndOverlaps() {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 2, text: "A", isFinal: true),
            TranscriptSegment(startTime: 0, endTime: 2, text: "A", isFinal: true),
            TranscriptSegment(startTime: 1.5, endTime: 4, text: "B-overlap", isFinal: true),
            TranscriptSegment(startTime: 4, endTime: 6, text: "C", isFinal: true)
        ]
        let merged = TranscriptTimeline.mergeFinals(segments)
        XCTAssertEqual(merged.first?.text, "A")
        XCTAssertFalse(merged.contains(where: { $0.startTime == 0 && $0.endTime == 2 && $0.text == "A" && merged.filter { $0.text == "A" }.count > 1 }))
        XCTAssertTrue(TranscriptTimeline.coversRecordingDuration(merged, duration: 6))
    }

    func testProductionTranscriberReplaysBackgroundBuffersAtOriginalTimelineOffset() async throws {
        let source = ControllableAudioBufferSource()
        let session = ControllableSpeechAnalysisSession()
        session.resultForReceivedBuffer = { index in
            TranscriptSegment(
                startTime: Double(index) * 0.01,
                endTime: Double(index + 1) * 0.01,
                text: "后台\(index)",
                isFinal: true
            )
        }
        let transcriber = SpeechAnalyzerTranscriber(
            audioSource: source,
            analysisSession: session
        )
        var snapshots: [[TranscriptSegment]] = []
        try await transcriber.start(
            recordingURL: URL(filePath: "/tmp/unused-recording.m4a")
        ) { snapshots.append($0) }
        session.emit(
            TranscriptSegment(startTime: 0, endTime: 1, text: "前台", isFinal: true)
        )

        transcriber.noteAnalysisPaused(at: 1)
        source.emitTestBuffer()
        source.emitTestBuffer()
        await Task.yield()
        XCTAssertEqual(session.receivedBufferCount, 0)

        let caughtUp = try await transcriber.catchUp(
            from: URL(filePath: "/tmp/unused-recording.m4a"),
            alreadyCoveredUntil: 1
        )

        XCTAssertEqual(session.startCount, 2)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(session.receivedBufferCount, 2)
        XCTAssertEqual(caughtUp.map(\.text), ["后台0", "后台1"])
        XCTAssertEqual(caughtUp[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(caughtUp[1].endTime, 1.02, accuracy: 0.001)

        source.emitTestBuffer()
        await Task.yield()
        XCTAssertEqual(session.receivedBufferCount, 3)
        XCTAssertEqual(snapshots.last?.last?.text, "后台2")

        _ = try await transcriber.finalize(
            from: URL(filePath: "/tmp/unused-recording.m4a")
        )
        XCTAssertEqual(session.finishCount, 2)
    }

    private func makeDeps(transcriber: ControllableTranscriber) -> MeetingWorkflowDependencies {
        let keyStore = InMemoryAPIKeyStore(initial: "sk-test")
        let bookmarking = ControllableBookmarking()
        let folder = tempRoot.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = (try? bookmarking.makeBookmark(for: folder)) ?? Data()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: InMemoryBookmarkStore(data: bookmark),
            bookmarking: bookmarking
        )
        let recorder = ControllableAudioRecorder()
        recorder.simulatedCurrentTime = 9
        return MeetingWorkflowDependencies(
            audioRecorder: recorder,
            transcriber: transcriber,
            minutesGenerator: DemoMinutesGenerator(shouldFail: false),
            credentialChecker: StoreBackedCredentialChecker(store: keyStore),
            directoryAccess: access,
            assetWriter: ControllableAssetWriter(),
            mermaidGenerator: DeterministicMermaidGenerator(),
            mermaidRenderer: DemoMermaidRenderer(),
            apiKeyStore: keyStore,
            byokPreferences: InMemoryBYOKPreferences(),
            connectionTester: ControllableDemoConnectionTester(),
            microphonePermission: ControllableMicrophonePermission(granted: true)
        )
    }
}
