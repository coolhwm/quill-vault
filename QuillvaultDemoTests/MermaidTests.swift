import XCTest
@testable import QuillvaultDemo

@MainActor
final class MermaidTests: XCTestCase {
    func testDeterministicFlowchartFromConstrainedGraph() {
        let graph = CoreViewpointGraph(
            nodes: [
                GraphNode(id: "b", label: "B"),
                GraphNode(id: "a", label: "A")
            ],
            edges: [
                GraphEdge(from: "a", to: "b", label: "to")
            ]
        )
        let generator = DeterministicFlowchartGenerator()
        let first = generator.source(for: graph)
        let second = generator.source(for: graph)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("flowchart TD"))
        XCTAssertTrue(first.contains("a[\"A\"]"))
        XCTAssertTrue(first.contains("b[\"B\"]"))
        XCTAssertTrue(first.contains("a -->|to| b"))
        // Does not accept arbitrary model mermaid — only constrained graph input.
        XCTAssertFalse(first.contains("sequenceDiagram"))
    }

    func testOfflineRenderWithoutNetwork() async throws {
        let source = """
        flowchart TD
            a[\"Alpha\"]
            b[\"Beta\"]
            a -->|next| b
        """
        let renderer = ControllableMermaidRenderer()
        let diagram = try await renderer.render(source: source)
        XCTAssertEqual(diagram.nodeLabels, ["Alpha", "Beta"])
        XCTAssertEqual(diagram.edgeLabel, "next")
    }

    func testEditAndRerenderUpdatesCompletedAssets() async {
        let renderer = ControllableMermaidRenderer()
        let workflow = MeetingWorkflow(dependencies: makeDeps(renderer: renderer))
        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()
        XCTAssertEqual(workflow.phase, .completed)

        let edited = """
        flowchart TD
            x[\"Edited\"]
            y[\"Node\"]
            x -->|link| y
        """
        workflow.updateMermaidSource(edited)
        await workflow.rerenderMermaid()
        XCTAssertNil(workflow.mermaidRenderError)
        guard case let .completed(assets) = workflow.state else {
            return XCTFail("Expected completed")
        }
        XCTAssertEqual(assets.mermaidSource, edited)
        XCTAssertEqual(assets.renderedDiagram.nodeLabels, ["Edited", "Node"])
        XCTAssertEqual(renderer.renderCount, 2) // initial + rerender
    }

    func testParseFailureKeepsEditedSourceAndShowsError() async {
        let renderer = ControllableMermaidRenderer()
        let workflow = MeetingWorkflow(dependencies: makeDeps(renderer: renderer))
        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()

        let bad = "not a flowchart"
        workflow.updateMermaidSource(bad)
        await workflow.rerenderMermaid()
        XCTAssertEqual(workflow.editableMermaidSource, bad)
        XCTAssertNotNil(workflow.mermaidRenderError)
        guard case .completed = workflow.state else {
            return XCTFail("Should remain completed after render error")
        }
    }

    func testAtomicMinutesWriteFailureDoesNotReportSuccess() async {
        let writer = FailingMinutesAssetWriter()
        let workflow = MeetingWorkflow(dependencies: makeDeps(writer: writer))
        await workflow.startFaceToFaceSession()
        await workflow.finishFaceToFaceSession()
        // Source write succeeds; minutes write fails on second call.
        guard case let .failed(message) = workflow.state else {
            return XCTFail("Expected failed, got \(workflow.state)")
        }
        XCTAssertTrue(message.contains("minutes") || message.contains("写入") || message.contains("失败"))
        XCTAssertFalse(writer.leftPartialMinutesAsSuccess)
    }

    func testParserRejectsRemoteScripts() {
        XCTAssertThrowsError(
            try MermaidSourceParser.validate(
                """
                flowchart TD
                    a["A"]
                    https://evil.example/x.js
                """
            )
        )
    }

    private func makeDeps(
        renderer: ControllableMermaidRenderer = ControllableMermaidRenderer(),
        writer: (any MeetingAssetWriting)? = nil
    ) -> MeetingWorkflowDependencies {
        let keyStore = InMemoryAPIKeyStore(initial: "sk")
        let bookmarking = ControllableBookmarking()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MermaidTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = (try? bookmarking.makeBookmark(for: folder)) ?? Data()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: InMemoryBookmarkStore(data: bookmark),
            bookmarking: bookmarking
        )
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, text: "小林负责完成真机测试", isFinal: true)
        ]
        return MeetingWorkflowDependencies(
            audioRecorder: ControllableAudioRecorder(),
            transcriber: ControllableTranscriber(
                liveEvents: segments,
                finalTranscript: Transcript(segments: segments)
            ),
            minutesGenerator: ControllableMinutesGenerator(failTimes: 0),
            credentialChecker: StoreBackedCredentialChecker(store: keyStore),
            directoryAccess: access,
            assetWriter: writer ?? ControllableAssetWriter(),
            mermaidGenerator: DeterministicFlowchartGenerator(),
            mermaidRenderer: renderer,
            apiKeyStore: keyStore,
            byokPreferences: InMemoryBYOKPreferences(),
            connectionTester: ControllableDemoConnectionTester(),
            microphonePermission: ControllableMicrophonePermission(granted: true)
        )
    }
}

@MainActor
private final class FailingMinutesAssetWriter: MeetingAssetWriting {
    private(set) var leftPartialMinutesAsSuccess = false
    private var call = 0

    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes?,
        mermaidSource: String?,
        to directory: URL
    ) async throws -> [MeetingAssetFile] {
        call += 1
        if minutes == nil {
            return [
                MeetingAssetFile(name: "recording.m4a", detail: "ok"),
                MeetingAssetFile(name: "transcript.md", detail: "ok")
            ]
        }
        // Simulate atomic write failure — must not claim success with partial minutes.
        leftPartialMinutesAsSuccess = false
        throw MermaidError.writeFailed("simulated atomic minutes failure")
    }
}
