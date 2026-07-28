import XCTest
@testable import QuillvaultDemo

@MainActor
final class MeetingWorkflowTests: XCTestCase {
    func testUserIntentCompletesWorkflowAndProducesMeetingAssets() async {
        let workflow = MeetingWorkflow(dependencies: .successfulDemo)

        XCTAssertEqual(workflow.phase, .setup)

        await workflow.startFaceToFaceSession()

        XCTAssertEqual(workflow.phase, .recording)
        XCTAssertEqual(workflow.liveTranscript.map(\.text), [
            "我们需要验证会议工作流。",
            "小林负责完成真机测试，周五前反馈。"
        ])

        await workflow.finishFaceToFaceSession()

        XCTAssertEqual(
            workflow.phaseHistory,
            [.setup, .recording, .finalizing, .generating, .completed]
        )
        guard case let .completed(assets) = workflow.state else {
            return XCTFail("Expected completed meeting assets")
        }
        XCTAssertEqual(assets.transcript.segments.count, 2)
        XCTAssertEqual(assets.minutes.title, "Quillvault 技术闭环讨论")
        XCTAssertEqual(assets.minutes.actionItems.first?.owner, "小林")
        XCTAssertEqual(
            assets.mermaidSource,
            """
            flowchart TD
                workflow["跑通 MeetingWorkflow"]
                device["完成真机测试"]
                workflow -->|需要| device
            """
        )
        XCTAssertEqual(
            Set(assets.files.map(\.name)),
            ["recording.m4a", "transcript.md", "minutes.md"]
        )
        XCTAssertEqual(assets.renderedDiagram.title, "跑通 MeetingWorkflow → 完成真机测试")
        XCTAssertEqual(
            assets.renderedDiagram.nodeLabels,
            ["跑通 MeetingWorkflow", "完成真机测试"]
        )
        XCTAssertEqual(assets.renderedDiagram.edgeLabel, "需要")
    }
}
