import Foundation
import Observation

struct TranscriptSegment: Equatable, Sendable, Identifiable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let isFinal: Bool

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
    }
}

struct Transcript: Equatable, Sendable {
    let segments: [TranscriptSegment]
}

struct ActionItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let task: String
    let owner: String
    let deadline: String
    let evidence: String

    init(
        id: UUID = UUID(),
        task: String,
        owner: String,
        deadline: String,
        evidence: String
    ) {
        self.id = id
        self.task = task
        self.owner = owner
        self.deadline = deadline
        self.evidence = evidence
    }
}

struct TopicChapter: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let summary: String

    init(
        id: UUID = UUID(),
        title: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        summary: String
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.summary = summary
    }
}

struct DecisionItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let statement: String
    let reason: String
    let evidence: String

    init(
        id: UUID = UUID(),
        statement: String,
        reason: String,
        evidence: String
    ) {
        self.id = id
        self.statement = statement
        self.reason = reason
        self.evidence = evidence
    }
}

struct GraphNode: Equatable, Sendable {
    let id: String
    let label: String
}

struct GraphEdge: Equatable, Sendable {
    let from: String
    let to: String
    let label: String
}

struct CoreViewpointGraph: Equatable, Sendable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
}

struct StructuredMinutes: Equatable, Sendable {
    let title: String
    let overview: String
    let summary: String
    let chapters: [TopicChapter]
    let decisions: [DecisionItem]
    let actionItems: [ActionItem]
    let risks: [String]
    let unresolvedQuestions: [String]
    let coreViewpointGraph: CoreViewpointGraph
    let sourceLinks: [String]

    /// Compatibility helper for older call sites that only had decision strings.
    var decisionStatements: [String] { decisions.map(\.statement) }
}

struct RenderedDiagram: Equatable, Sendable {
    let title: String
    let nodeLabels: [String]
    let edgeLabel: String
}

struct MeetingAssetFile: Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let detail: String
}

struct MeetingAssets: Equatable, Sendable {
    let recordingURL: URL
    let transcript: Transcript
    let minutes: StructuredMinutes
    let mermaidSource: String
    let renderedDiagram: RenderedDiagram
    let files: [MeetingAssetFile]
}

enum MeetingWorkflowPhase: String, CaseIterable, Equatable, Sendable {
    case setup
    case recording
    case finalizing
    case generating
    case completed
    case failed

    var title: String {
        switch self {
        case .setup: "准备"
        case .recording: "录音中"
        case .finalizing: "整理逐字稿"
        case .generating: "生成纪要"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }
}

enum MeetingWorkflowState: Equatable, Sendable {
    case setup
    case recording
    case finalizing
    case generating
    case completed(MeetingAssets)
    case failed(String)

    var phase: MeetingWorkflowPhase {
        switch self {
        case .setup: .setup
        case .recording: .recording
        case .finalizing: .finalizing
        case .generating: .generating
        case .completed: .completed
        case .failed: .failed
        }
    }
}

@MainActor
protocol AudioRecording {
    /// Starts continuous m4a capture under the authoritative directory (prefer a meeting asset folder).
    func start(in directory: URL) async throws -> URL
    func stop() async throws -> URL
    /// Audio-clock duration of the active recording (not wall clock).
    var currentTime: TimeInterval { get }
}

@MainActor
protocol Transcribing {
    /// Starts live transcription against the sole recording file (must not open a second mic capture).
    func start(
        recordingURL: URL,
        onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void
    ) async throws
    /// Marks that system analysis may have paused (background/lock). Recording must continue.
    func noteAnalysisPaused(at audioTime: TimeInterval)
    /// Catch up unanalyzed ranges from the saved recording (foreground return or stop).
    func catchUp(from recordingURL: URL, alreadyCoveredUntil: TimeInterval) async throws -> [TranscriptSegment]
    func finalize(from recordingURL: URL) async throws -> Transcript
}

@MainActor
protocol MinutesGenerating {
    /// Generates structured minutes from final transcript text only (never audio).
    func generate(
        from transcript: Transcript,
        onProgress: (@MainActor @Sendable (MinutesGenerationProgress) -> Void)?
    ) async throws -> StructuredMinutes
}

extension MinutesGenerating {
    func generate(from transcript: Transcript) async throws -> StructuredMinutes {
        try await generate(from: transcript, onProgress: nil)
    }
}

struct MinutesGenerationProgress: Equatable, Sendable {
    let message: String
    let completedSteps: Int
    let totalSteps: Int
    let receivedCharacters: Int
}

/// Captures the last outbound BYOK payload for privacy assertions in tests.
@MainActor
protocol BYOKRequestInspecting: AnyObject {
    var lastRequestBodyJSON: String? { get }
}

@MainActor
protocol BYOKCredentialChecking {
    func hasBYOKCredential() async -> Bool
}

@MainActor
protocol AuthoritativeDirectoryAccessing {
    func currentState() async -> AuthoritativeDirectoryState
    func selectDirectory(_ url: URL) async throws -> AuthoritativeDirectoryInfo
    func authorizedDirectory() async throws -> URL
}

@MainActor
protocol MeetingAssetWriting {
    /// Writes recording + transcript immediately. Minutes are optional so failures never leave partial minutes.md.
    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes?,
        mermaidSource: String?,
        to directory: URL
    ) async throws -> [MeetingAssetFile]
}

@MainActor
protocol MermaidGenerating {
    func source(for graph: CoreViewpointGraph) -> String
}

@MainActor
protocol MermaidRendering {
    func render(source: String) async throws -> RenderedDiagram
}

struct MeetingWorkflowDependencies {
    let audioRecorder: any AudioRecording
    let transcriber: any Transcribing
    let minutesGenerator: any MinutesGenerating
    let credentialChecker: any BYOKCredentialChecking
    let directoryAccess: any AuthoritativeDirectoryAccessing
    let assetWriter: any MeetingAssetWriting
    let mermaidGenerator: any MermaidGenerating
    let mermaidRenderer: any MermaidRendering
    let apiKeyStore: any APIKeyStoring
    let byokPreferences: any BYOKPreferencesStoring
    let connectionTester: any BYOKConnectionTesting
    let microphonePermission: any MicrophonePermissioning
}

@MainActor
@Observable
final class MeetingWorkflow {
    let dependencies: MeetingWorkflowDependencies
    private var authorizedDirectory: URL?
    private var activeRecordingURL: URL?
    private var recordingStartedAt: Date?
    private var finalizedTranscript: Transcript?
    private var sourceAssetFiles: [MeetingAssetFile] = []
    private var completedAssets: MeetingAssets?
    private(set) var editableMermaidSource: String = ""
    private(set) var mermaidRenderError: String?

    private(set) var state: MeetingWorkflowState = .setup
    private(set) var liveTranscript: [TranscriptSegment] = []
    private(set) var phaseHistory: [MeetingWorkflowPhase] = [.setup]
    private(set) var byokSettings: BYOKSettings = .deepSeekDefaults
    private(set) var byokConnectionTestState: BYOKConnectionTestState = .idle
    private(set) var directoryState: AuthoritativeDirectoryState = .unset
    /// Survives downstream transcription/generation failures so evidence is never lost.
    private(set) var preservedRecordingURL: URL?
    /// Last completed audio range end from live analysis (not a real-time display promise in background).
    private(set) var lastCompletedAudioEnd: TimeInterval = 0
    private(set) var analysisPaused = false
    private(set) var diagnosticNote: String?
    private(set) var minutesGenerationProgress: MinutesGenerationProgress?

    var phase: MeetingWorkflowPhase {
        state.phase
    }

    var recordingDuration: TimeInterval {
        let audioClock = dependencies.audioRecorder.currentTime
        if audioClock > 0 { return audioClock }
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    init(dependencies: MeetingWorkflowDependencies) {
        self.dependencies = dependencies
        reloadBYOKSettings()
        // Directory restore is async; callers also invoke reloadAuthoritativeDirectory().
        directoryState = .unset
    }

    func reloadBYOKSettings() {
        byokSettings = BYOKSettings(
            baseURL: dependencies.byokPreferences.baseURL,
            model: dependencies.byokPreferences.model,
            apiKeyField: "",
            hasStoredAPIKey: dependencies.apiKeyStore.hasKey()
        )
    }

    func setBYOKBaseURL(_ value: String) {
        byokSettings.baseURL = value
    }

    func setBYOKModel(_ value: String) {
        byokSettings.model = value
    }

    func setBYOKAPIKeyField(_ value: String) {
        byokSettings.apiKeyField = value
    }

    func saveAndTestBYOK() async {
        byokConnectionTestState = .testing
        do {
            let baseURL = byokSettings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = byokSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseURL.isEmpty else {
                throw BYOKConnectionError.invalidBaseURL
            }
            guard !model.isEmpty else {
                throw BYOKConnectionError.missingModel
            }

            dependencies.byokPreferences.baseURL = baseURL
            dependencies.byokPreferences.model = model

            let field = byokSettings.apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
            if !field.isEmpty {
                try dependencies.apiKeyStore.save(field)
            }

            guard let apiKey = try dependencies.apiKeyStore.load(), !apiKey.isEmpty else {
                throw BYOKConnectionError.missingAPIKey
            }

            let message = try await dependencies.connectionTester.testConnection(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey
            )
            byokSettings.apiKeyField = ""
            byokSettings.hasStoredAPIKey = dependencies.apiKeyStore.hasKey()
            byokSettings.baseURL = baseURL
            byokSettings.model = model
            byokConnectionTestState = .succeeded(message)
        } catch {
            byokSettings.hasStoredAPIKey = dependencies.apiKeyStore.hasKey()
            byokConnectionTestState = .failed(error.localizedDescription)
        }
    }

    func reloadAuthoritativeDirectory() async {
        directoryState = await dependencies.directoryAccess.currentState()
    }

    func applySelectedDirectory(_ url: URL) async {
        do {
            let info = try await dependencies.directoryAccess.selectDirectory(url)
            directoryState = .ready(info)
        } catch {
            directoryState = .needsReauthorization(error.localizedDescription)
        }
    }

    func startFaceToFaceSession() async {
        guard phase == .setup || phase == .failed else { return }

        do {
            guard await dependencies.credentialChecker.hasBYOKCredential() else {
                throw DemoWorkflowError.missingCredential
            }
            directoryState = await dependencies.directoryAccess.currentState()
            guard directoryState.isWritable else {
                if case let .needsReauthorization(detail) = directoryState {
                    throw AuthoritativeDirectoryError.bookmarkInvalid(detail)
                }
                throw AuthoritativeDirectoryError.notSelected
            }
            let micGranted = await dependencies.microphonePermission.requestAccess()
            guard micGranted else {
                throw RecordingError.microphoneDenied
            }

            let directory = try await dependencies.directoryAccess.authorizedDirectory()
            let recordingURL = try await dependencies.audioRecorder.start(in: directory)
            self.authorizedDirectory = directory
            self.activeRecordingURL = recordingURL
            self.preservedRecordingURL = recordingURL
            self.recordingStartedAt = Date()
            self.lastCompletedAudioEnd = 0
            self.analysisPaused = false
            self.diagnosticNote = nil
            liveTranscript = []
            transition(to: .recording)

            // Transcription must not open a second mic path; failures must not reverse recording.
            do {
                try await dependencies.transcriber.start(recordingURL: recordingURL) { [weak self] segments in
                    guard let self else { return }
                    self.liveTranscript = segments
                    self.lastCompletedAudioEnd = TranscriptTimeline.lastCoveredEnd(in: segments)
                }
            } catch {
                liveTranscript = []
                diagnosticNote = "实时转写启动失败，录音继续：\(error.localizedDescription)"
            }
        } catch {
            // Do not enter a fake recording state when setup fails before record starts.
            activeRecordingURL = nil
            recordingStartedAt = nil
            transition(to: .failed(error.localizedDescription))
        }
    }

    /// Call when App enters background or device locks. Recording continues; analysis may pause.
    func handleEnteredBackground() {
        guard phase == .recording else { return }
        analysisPaused = true
        let audioTime = recordingDuration
        dependencies.transcriber.noteAnalysisPaused(at: audioTime)
        diagnosticNote = String(
            format: "已进入后台/锁屏：录音继续。最后完成分析至 %.1f 秒。",
            lastCompletedAudioEnd
        )
    }

    /// Call when returning to foreground: catch up unanalyzed audio from the saved recording.
    func handleBecameActive() async {
        guard phase == .recording, analysisPaused, let recordingURL = activeRecordingURL else { return }
        do {
            let caughtUp = try await dependencies.transcriber.catchUp(
                from: recordingURL,
                alreadyCoveredUntil: lastCompletedAudioEnd
            )
            if !caughtUp.isEmpty {
                let merged = TranscriptTimeline.mergeFinals(liveTranscript + caughtUp)
                liveTranscript = merged
                lastCompletedAudioEnd = TranscriptTimeline.lastCoveredEnd(in: merged)
            }
            analysisPaused = false
            diagnosticNote = String(
                format: "前台追平完成，覆盖至 %.1f 秒。",
                lastCompletedAudioEnd
            )
        } catch {
            // Audio remains; show diagnostic without aborting recording.
            diagnosticNote = "前台追平失败（录音仍保留）：\(error.localizedDescription)"
        }
    }

    func finishFaceToFaceSession() async {
        guard phase == .recording, let directory = authorizedDirectory else { return }

        transition(to: .finalizing)
        let recordingURL: URL
        do {
            recordingURL = try await dependencies.audioRecorder.stop()
            preservedRecordingURL = recordingURL
            activeRecordingURL = recordingURL
        } catch {
            transition(to: .failed(error.localizedDescription))
            return
        }

        let recordingDurationSnapshot = max(
            recordingDuration,
            dependencies.audioRecorder.currentTime,
            lastCompletedAudioEnd
        )
        recordingStartedAt = nil

        let transcript: Transcript
        do {
            let caughtUp = try await dependencies.transcriber.catchUp(
                from: recordingURL,
                alreadyCoveredUntil: lastCompletedAudioEnd
            )
            if !caughtUp.isEmpty {
                liveTranscript = TranscriptTimeline.mergeFinals(liveTranscript + caughtUp)
                lastCompletedAudioEnd = TranscriptTimeline.lastCoveredEnd(in: liveTranscript)
            }
            var finalized = try await dependencies.transcriber.finalize(from: recordingURL)
            finalized = Transcript(segments: TranscriptTimeline.mergeFinals(finalized.segments))
            let durationForCoverage = max(recordingDurationSnapshot, lastCompletedAudioEnd)
            if !TranscriptTimeline.coversRecordingDuration(
                finalized.segments,
                duration: durationForCoverage
            ) {
                // Spec: finalization must prevent missing ranges — block BYOK, keep recording.
                finalizedTranscript = finalized
                liveTranscript = finalized.segments
                _ = try? await dependencies.assetWriter.write(
                    recordingURL: recordingURL,
                    transcript: finalized,
                    minutes: nil,
                    mermaidSource: nil,
                    to: directory
                )
                transition(
                    to: .failed(
                        "最终逐字稿时间轴存在重复或空洞（录音时长约 \(String(format: "%.1f", durationForCoverage)) 秒）。原始录音与逐字稿已保留，未生成 minutes.md。"
                    )
                )
                return
            }
            transcript = finalized
            liveTranscript = transcript.segments
            analysisPaused = false
        } catch {
            transition(
                to: .failed(
                    "\(error.localizedDescription)（原始录音已保留：\(recordingURL.lastPathComponent)）"
                )
            )
            return
        }

        finalizedTranscript = transcript
        do {
            sourceAssetFiles = try await dependencies.assetWriter.write(
                recordingURL: recordingURL,
                transcript: transcript,
                minutes: nil,
                mermaidSource: nil,
                to: directory
            )
        } catch {
            transition(
                to: .failed(
                    "源资产写入失败：\(error.localizedDescription)（录音文件仍保留：\(recordingURL.lastPathComponent)）"
                )
            )
            return
        }

        await generateMinutesWithRetry(recordingURL: recordingURL, transcript: transcript, directory: directory)
    }

    /// Reuses a previously finalized meeting folder without recording or transcribing again.
    func generateMinutesFromExistingMeetingDirectory(_ directory: URL) async {
        guard phase == .setup || phase == .failed else { return }

        let accessedSecurityScope = directory.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        do {
            guard await dependencies.credentialChecker.hasBYOKCredential() else {
                throw DemoWorkflowError.missingCredential
            }

            let recordingURL = directory.appendingPathComponent("recording.m4a")
            guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                throw ExistingMeetingImportError.missingRecording
            }
            let recordingAttributes = try FileManager.default.attributesOfItem(atPath: recordingURL.path)
            let recordingSize = (recordingAttributes[.size] as? NSNumber)?.intValue ?? 0
            guard recordingSize > 0 else {
                throw ExistingMeetingImportError.missingRecording
            }

            let transcriptURL = directory.appendingPathComponent("transcript.md")
            guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
                throw ExistingMeetingImportError.missingTranscript
            }
            let transcriptMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
            let transcript = try ExistingTranscriptParser.parse(markdown: transcriptMarkdown)

            authorizedDirectory = directory
            activeRecordingURL = recordingURL
            preservedRecordingURL = recordingURL
            finalizedTranscript = transcript
            liveTranscript = transcript.segments
            lastCompletedAudioEnd = TranscriptTimeline.lastCoveredEnd(in: transcript.segments)
            diagnosticNote = "已读取现有 transcript.md；跳过录音与转写，直接生成纪要。"
            sourceAssetFiles = [
                MeetingAssetFile(name: "recording.m4a", detail: recordingURL.path),
                MeetingAssetFile(
                    name: "transcript.md",
                    detail: "\(transcript.segments.count) 个带时间戳片段"
                )
            ]

            await generateMinutesWithRetry(
                recordingURL: recordingURL,
                transcript: transcript,
                directory: directory
            )
        } catch {
            transition(to: .failed("导入已有会议失败：\(error.localizedDescription)"))
        }
    }

    /// Manual retry after BYOK failure. Requires a finalized transcript.
    func retryGenerateMinutes() async {
        guard let transcript = finalizedTranscript,
              let recordingURL = preservedRecordingURL ?? activeRecordingURL,
              let directory = authorizedDirectory
        else {
            transition(to: .failed("无法重试：缺少最终逐字稿或录音。"))
            return
        }
        guard phase == .failed || phase == .setup else { return }
        let accessedSecurityScope = directory.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        await generateMinutesWithRetry(
            recordingURL: recordingURL,
            transcript: transcript,
            directory: directory
        )
    }

    private func generateMinutesWithRetry(
        recordingURL: URL,
        transcript: Transcript,
        directory: URL
    ) async {
        minutesGenerationProgress = MinutesGenerationProgress(
            message: "准备发送最终逐字稿…",
            completedSteps: 0,
            totalSteps: 1,
            receivedCharacters: 0
        )
        transition(to: .generating)
        do {
            let minutes = try await generateMinutesAllowingOneRetry(from: transcript)
            // Always derive Mermaid from constrained graph — never model-authored source.
            let mermaidSource = dependencies.mermaidGenerator.source(
                for: minutes.coreViewpointGraph
            )
            let renderedDiagram = try await dependencies.mermaidRenderer.render(
                source: mermaidSource
            )
            let files = try await dependencies.assetWriter.write(
                recordingURL: recordingURL,
                transcript: transcript,
                minutes: minutes,
                mermaidSource: mermaidSource,
                to: directory
            )
            let assets = MeetingAssets(
                recordingURL: recordingURL,
                transcript: transcript,
                minutes: minutes,
                mermaidSource: mermaidSource,
                renderedDiagram: renderedDiagram,
                files: files
            )
            recordingStartedAt = nil
            editableMermaidSource = mermaidSource
            mermaidRenderError = nil
            completedAssets = assets
            minutesGenerationProgress = nil
            transition(to: .completed(assets))
        } catch {
            // Do not leave a successful completed state or partial authoritative minutes.
            transition(
                to: .failed(
                    "\(error.localizedDescription)（recording.m4a 与 transcript.md 已保留，未写入残缺 minutes.md。可手动重试。）"
                )
            )
        }
    }

    func updateMermaidSource(_ source: String) {
        editableMermaidSource = source
        mermaidRenderError = nil
    }

    func rerenderMermaid() async {
        guard case .completed = state else { return }
        do {
            let rendered = try await dependencies.mermaidRenderer.render(
                source: editableMermaidSource
            )
            mermaidRenderError = nil
            if var assets = completedAssets {
                assets = MeetingAssets(
                    recordingURL: assets.recordingURL,
                    transcript: assets.transcript,
                    minutes: assets.minutes,
                    mermaidSource: editableMermaidSource,
                    renderedDiagram: rendered,
                    files: assets.files
                )
                completedAssets = assets
                state = .completed(assets)
            }
        } catch {
            // Keep edited source; show diagnostic only.
            mermaidRenderError = error.localizedDescription
        }
    }

    private func generateMinutesAllowingOneRetry(from transcript: Transcript) async throws -> StructuredMinutes {
        let progress: @MainActor @Sendable (MinutesGenerationProgress) -> Void = { [weak self] update in
            self?.minutesGenerationProgress = update
        }
        do {
            return try await dependencies.minutesGenerator.generate(
                from: transcript,
                onProgress: progress
            )
        } catch {
            // Retry only empty content / invalid JSON / business validation — not auth/network.
            guard Self.isRetriableMinutesError(error) else { throw error }
            return try await dependencies.minutesGenerator.generate(
                from: transcript,
                onProgress: progress
            )
        }
    }

    private static func isRetriableMinutesError(_ error: Error) -> Bool {
        if let validation = error as? MinutesValidationError {
            switch validation {
            case .emptyContent, .invalidJSON, .missingField, .invalidTimeRange:
                return true
            case .generationFailed:
                return false
            }
        }
        if let connection = error as? BYOKConnectionError {
            switch connection {
            case .emptyContent, .invalidJSON, .invalidStructure:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func transition(to nextState: MeetingWorkflowState) {
        state = nextState
        phaseHistory.append(nextState.phase)
    }
}

enum DemoWorkflowError: LocalizedError {
    case missingCredential
    case rejectedDemoResponse

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "缺少 BYOK 凭据：请先在设置中保存 API Key"
        case .rejectedDemoResponse:
            "BYOK 替身返回了可诊断的失败；录音与逐字稿仍保留"
        }
    }
}
