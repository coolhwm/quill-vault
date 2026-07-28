import XCTest
@testable import QuillvaultDemo

@MainActor
final class ForegroundRecordingTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillvaultRecTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testMicrophoneDenialDoesNotEnterRecordingState() async {
        let deps = makeDeps(micGranted: false)
        let workflow = MeetingWorkflow(dependencies: deps)

        await workflow.startFaceToFaceSession()

        XCTAssertEqual(workflow.phase, .failed)
        guard case let .failed(message) = workflow.state else {
            return XCTFail("Expected failed")
        }
        XCTAssertTrue(message.contains("麦克风"))
        XCTAssertNil(workflow.preservedRecordingURL)
        XCTAssertNotEqual(workflow.phase, .recording)
    }

    func testVolatileAndFinalSegmentsMergeWithTimeRanges() async {
        let volatile = TranscriptSegment(
            startTime: 1.0,
            endTime: 2.5,
            text: "临时结果",
            isFinal: false
        )
        let finalA = TranscriptSegment(
            startTime: 0,
            endTime: 2.5,
            text: "最终第一句",
            isFinal: true
        )
        let finalB = TranscriptSegment(
            startTime: 2.5,
            endTime: 5.0,
            text: "最终第二句",
            isFinal: true
        )
        let transcriber = ControllableTranscriber(
            liveEvents: [volatile, finalA],
            finalTranscript: Transcript(segments: [finalA, finalB])
        )
        let workflow = MeetingWorkflow(dependencies: makeDeps(transcriber: transcriber))

        await workflow.startFaceToFaceSession()
        XCTAssertEqual(workflow.phase, .recording)
        // After live events: finalA only (volatile replaced once final arrives in merger path of emit sequence)
        XCTAssertTrue(workflow.liveTranscript.contains(where: { $0.isFinal && $0.text == "最终第一句" }))
        XCTAssertEqual(workflow.liveTranscript.filter(\.isFinal).count, 1)

        // Late volatile should trail finals
        transcriber.emit(
            TranscriptSegment(startTime: 5.0, endTime: 6.0, text: "新的临时", isFinal: false)
        )
        XCTAssertEqual(workflow.liveTranscript.last?.isFinal, false)
        XCTAssertEqual(workflow.liveTranscript.last?.text, "新的临时")
        XCTAssertTrue(workflow.liveTranscript.filter(\.isFinal).allSatisfy { $0.endTime >= $0.startTime })

        await workflow.finishFaceToFaceSession()
        guard case let .completed(assets) = workflow.state else {
            return XCTFail("Expected completed, got \(workflow.state)")
        }
        XCTAssertEqual(assets.transcript.segments.map(\.text), ["最终第一句", "最终第二句"])
        XCTAssertTrue(assets.transcript.segments.allSatisfy(\.isFinal))
        XCTAssertEqual(assets.transcript.segments[0].startTime, 0)
        XCTAssertEqual(assets.transcript.segments[0].endTime, 2.5)
    }

    func testTranscriptionFinalizeFailurePreservesRecording() async throws {
        let recorder = ControllableAudioRecorder()
        let transcriber = ControllableTranscriber(
            liveEvents: [
                TranscriptSegment(startTime: 0, endTime: 1, text: "hi", isFinal: true)
            ],
            finalizeError: TranscriptionError.failed("模拟转写失败")
        )
        let workflow = MeetingWorkflow(
            dependencies: makeDeps(recorder: recorder, transcriber: transcriber)
        )

        await workflow.startFaceToFaceSession()
        XCTAssertEqual(workflow.phase, .recording)
        let recordingURL = try XCTUnwrap(workflow.preservedRecordingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))

        await workflow.finishFaceToFaceSession()
        guard case let .failed(message) = workflow.state else {
            return XCTFail("Expected failed after transcription error")
        }
        XCTAssertTrue(message.contains("转写") || message.contains("保留"))
        XCTAssertEqual(workflow.preservedRecordingURL, recordingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
    }

    func testSuccessfulStopWritesRecordingAndTimestampedTranscriptAssets() async throws {
        let assetWriter = ControllableAssetWriter()
        let finals = [
            TranscriptSegment(startTime: 0, endTime: 1.5, text: "开场", isFinal: true),
            TranscriptSegment(startTime: 1.5, endTime: 4.0, text: "讨论方案", isFinal: true)
        ]
        let workflow = MeetingWorkflow(
            dependencies: makeDeps(
                transcriber: ControllableTranscriber(
                    liveEvents: finals,
                    finalTranscript: Transcript(segments: finals)
                ),
                assetWriter: assetWriter
            )
        )

        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()

        guard case let .completed(assets) = workflow.state else {
            return XCTFail("Expected completed")
        }
        XCTAssertTrue(assets.files.map(\.name).contains("recording.m4a"))
        XCTAssertTrue(assets.files.map(\.name).contains("transcript.md"))
        XCTAssertNotNil(assetWriter.lastRecordingURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(assetWriter.lastRecordingURL).path)
        )
        XCTAssertEqual(assetWriter.lastTranscript?.segments.count, 2)
        let expectedDir = try await workflow.dependencies.directoryAccess.authorizedDirectory()
        XCTAssertEqual(assetWriter.wroteTo?.path, expectedDir.path)
    }

    func testLiveTranscriptMergerKeepsFinalsAndSingleVolatile() {
        let final = TranscriptSegment(startTime: 0, endTime: 1, text: "F", isFinal: true)
        let v1 = TranscriptSegment(startTime: 1, endTime: 2, text: "V1", isFinal: false)
        let v2 = TranscriptSegment(startTime: 1, endTime: 2.5, text: "V2", isFinal: false)
        var merged = LiveTranscriptMerger.applying(final, to: [])
        merged = LiveTranscriptMerger.applying(v1, to: merged)
        merged = LiveTranscriptMerger.applying(v2, to: merged)
        XCTAssertEqual(merged.map(\.text), ["F", "V2"])
        XCTAssertEqual(merged.filter(\.isFinal).count, 1)
        XCTAssertEqual(merged.filter { !$0.isFinal }.count, 1)
    }

    private func makeDeps(
        micGranted: Bool = true,
        recorder: ControllableAudioRecorder? = nil,
        transcriber: ControllableTranscriber? = nil,
        assetWriter: ControllableAssetWriter? = nil
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
        let defaultSegments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "默认", isFinal: true)
        ]
        return MeetingWorkflowDependencies(
            audioRecorder: recorder ?? ControllableAudioRecorder(),
            transcriber: transcriber ?? ControllableTranscriber(
                liveEvents: defaultSegments,
                finalTranscript: Transcript(segments: defaultSegments)
            ),
            minutesGenerator: DemoMinutesGenerator(shouldFail: false),
            credentialChecker: StoreBackedCredentialChecker(store: keyStore),
            directoryAccess: access,
            assetWriter: assetWriter ?? ControllableAssetWriter(),
            mermaidGenerator: DeterministicMermaidGenerator(),
            mermaidRenderer: DemoMermaidRenderer(),
            apiKeyStore: keyStore,
            byokPreferences: InMemoryBYOKPreferences(),
            connectionTester: ControllableDemoConnectionTester(),
            microphonePermission: ControllableMicrophonePermission(granted: micGranted)
        )
    }
}
