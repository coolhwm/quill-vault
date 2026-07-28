import Foundation

@MainActor
extension MeetingWorkflowDependencies {
    /// Full fake chain for the disposable demo path and unit tests.
    static let successfulDemo = makeControlled(failingGeneration: false, seedAPIKey: "demo-seed-key")
    static let failingDemo = makeControlled(failingGeneration: true, seedAPIKey: "demo-seed-key")

    /// Live BYOK + authoritative directory + device recording/transcription.
    static var liveSetup: MeetingWorkflowDependencies {
        let keyStore = KeychainAPIKeyStore()
        let directoryAccess = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: UserDefaultsBookmarkStore(),
            bookmarking: SystemSecurityScopedBookmarking()
        )
        return MeetingWorkflowDependencies(
            audioRecorder: DeviceAudioRecorder(),
            transcriber: SpeechAnalyzerTranscriber(),
            minutesGenerator: DeepSeekMinutesGenerator(
                apiKeyStore: keyStore,
                preferences: UserDefaultsBYOKPreferences()
            ),
            credentialChecker: StoreBackedCredentialChecker(store: keyStore),
            directoryAccess: directoryAccess,
            assetWriter: FileMeetingAssetWriter(),
            mermaidGenerator: DeterministicFlowchartGenerator(),
            mermaidRenderer: OfflineMermaidRenderer(allowNetwork: false),
            apiKeyStore: keyStore,
            byokPreferences: UserDefaultsBYOKPreferences(),
            connectionTester: OpenAICompatibleConnectionTester(),
            microphonePermission: SystemMicrophonePermission()
        )
    }

    private static func makeControlled(
        failingGeneration: Bool,
        seedAPIKey: String?
    ) -> MeetingWorkflowDependencies {
        let keyStore = InMemoryAPIKeyStore(initial: seedAPIKey)
        let bookmarking = ControllableBookmarking()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Quillvault-Demo-Controlled", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = (try? bookmarking.makeBookmark(for: folder)) ?? Data("controlled".utf8)
        let store = InMemoryBookmarkStore(data: bookmark)
        let directoryAccess = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
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
            minutesGenerator: ControllableMinutesGenerator(
                failTimes: failingGeneration ? 2 : 0,
                successMinutes: StructuredMinutes(
                    title: "Quillvault 技术闭环讨论",
                    overview: "用受控替身验证面对面会话的完整编排入口。",
                    summary: "团队决定先跑通 MeetingWorkflow，再逐段替换真实系统能力。",
                    chapters: [
                        TopicChapter(
                            title: "工作流验证",
                            startTime: 0,
                            endTime: 7.8,
                            summary: "确认 MeetingWorkflow 切面"
                        )
                    ],
                    decisions: [
                        DecisionItem(
                            statement: "以 MeetingWorkflow 作为唯一高层编排与自动化测试切面。",
                            reason: "降低耦合",
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
                    risks: ["当前链路使用受控替身，不能代表真实系统能力已验证。"],
                    unresolvedQuestions: ["真实 SpeechAnalyzer 的后台补齐表现如何？"],
                    coreViewpointGraph: CoreViewpointGraph(
                        nodes: [
                            GraphNode(id: "workflow", label: "跑通 MeetingWorkflow"),
                            GraphNode(id: "device", label: "完成真机测试")
                        ],
                        edges: [
                            GraphEdge(from: "workflow", to: "device", label: "需要")
                        ]
                    ),
                    sourceLinks: ["./transcript.md", "./recording.m4a"]
                )
            ),
            credentialChecker: StoreBackedCredentialChecker(store: keyStore),
            directoryAccess: directoryAccess,
            assetWriter: ControllableAssetWriter(),
            mermaidGenerator: DeterministicFlowchartGenerator(),
            mermaidRenderer: ControllableMermaidRenderer(),
            apiKeyStore: keyStore,
            byokPreferences: InMemoryBYOKPreferences(),
            connectionTester: ControllableDemoConnectionTester(),
            microphonePermission: ControllableMicrophonePermission(granted: true)
        )
    }
}

@MainActor
final class DemoAudioRecorder: AudioRecording {
    private let recordingURL = URL(filePath: "/受控替身/recording.m4a")

    func start(in directory: URL) async throws -> URL {
        try await demoPause()
        return recordingURL
    }

    func stop() async throws -> URL {
        try await demoPause()
        return recordingURL
    }
}

@MainActor
struct DemoTranscriber: Transcribing {
    private let segments = [
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

    func start(onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void) async throws {
        try await demoPause()
        onUpdate(segments)
    }

    func noteAnalysisPaused(at audioTime: TimeInterval) {}

    func catchUp(
        from recordingURL: URL,
        alreadyCoveredUntil: TimeInterval
    ) async throws -> [TranscriptSegment] {
        []
    }

    func finalize(from recordingURL: URL) async throws -> Transcript {
        try await demoPause()
        return Transcript(segments: segments)
    }
}

@MainActor
struct DemoMinutesGenerator: MinutesGenerating {
    let shouldFail: Bool

    func generate(from transcript: Transcript) async throws -> StructuredMinutes {
        try await demoPause()
        if shouldFail {
            throw DemoWorkflowError.rejectedDemoResponse
        }

        return StructuredMinutes(
            title: "Quillvault 技术闭环讨论",
            overview: "用受控替身验证面对面会话的完整编排入口。",
            summary: "团队决定先跑通 MeetingWorkflow，再逐段替换真实系统能力。",
            chapters: [
                TopicChapter(
                    title: "工作流验证",
                    startTime: 0,
                    endTime: 7.8,
                    summary: "确认 MeetingWorkflow 切面"
                )
            ],
            decisions: [
                DecisionItem(
                    statement: "以 MeetingWorkflow 作为唯一高层编排与自动化测试切面。",
                    reason: "降低耦合",
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
            risks: ["当前链路使用受控替身，不能代表真实系统能力已验证。"],
            unresolvedQuestions: ["真实 SpeechAnalyzer 的后台补齐表现如何？"],
            coreViewpointGraph: CoreViewpointGraph(
                nodes: [
                    GraphNode(id: "workflow", label: "跑通 MeetingWorkflow"),
                    GraphNode(id: "device", label: "完成真机测试")
                ],
                edges: [
                    GraphEdge(from: "workflow", to: "device", label: "需要")
                ]
            ),
            sourceLinks: ["./transcript.md", "./recording.m4a"]
        )
    }
}

@MainActor
struct DemoDirectoryAccess: AuthoritativeDirectoryAccessing {
    private let url = URL(filePath: "/受控替身/Quillvault-Demo")

    func currentState() async -> AuthoritativeDirectoryState {
        .ready(
            AuthoritativeDirectoryInfo(
                displayName: "Quillvault-Demo",
                pathDescription: url.path,
                isAccessible: true
            )
        )
    }

    func selectDirectory(_ url: URL) async throws -> AuthoritativeDirectoryInfo {
        AuthoritativeDirectoryInfo(
            displayName: url.lastPathComponent,
            pathDescription: url.path,
            isAccessible: true
        )
    }

    func authorizedDirectory() async throws -> URL {
        url
    }
}

@MainActor
struct DemoAssetWriter: MeetingAssetWriting {
    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes?,
        mermaidSource: String?,
        to directory: URL
    ) async throws -> [MeetingAssetFile] {
        try await demoPause()
        var files = [
            MeetingAssetFile(name: "recording.m4a", detail: "原始录音 · 受控替身"),
            MeetingAssetFile(name: "transcript.md", detail: "2 个带时间范围的逐字稿片段")
        ]
        if minutes != nil {
            files.append(MeetingAssetFile(name: "minutes.md", detail: "结构化纪要 + 内嵌 Mermaid"))
        }
        return files
    }
}

@MainActor
struct DeterministicMermaidGenerator: MermaidGenerating {
    private let impl = DeterministicFlowchartGenerator()
    func source(for graph: CoreViewpointGraph) -> String {
        impl.source(for: graph)
    }
}

@MainActor
struct DemoMermaidRenderer: MermaidRendering {
    func render(source: String) async throws -> RenderedDiagram {
        try await demoPause()
        return try MermaidSourceParser.previewDiagram(from: source)
    }
}

@MainActor
final class ControllableDemoConnectionTester: BYOKConnectionTesting {
    func testConnection(baseURL: String, model: String, apiKey: String) async throws -> String {
        try await demoPause()
        return "连接测试通过：已返回代表性结构化字段（受控替身）"
    }
}

@MainActor
private func demoPause() async throws {
    try await Task.sleep(for: .milliseconds(120))
}
