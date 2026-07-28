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
    let decisions: [String]
    let actionItems: [ActionItem]
    let risks: [String]
    let unresolvedQuestions: [String]
    let coreViewpointGraph: CoreViewpointGraph
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
    func start(in directory: URL) async throws -> URL
    func stop() async throws -> URL
}

@MainActor
protocol Transcribing {
    /// Starts live transcription and reports merged volatile/final segments via `onUpdate`.
    func start(onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void) async throws
    /// Marks that system analysis may have paused (background/lock). Recording must continue.
    func noteAnalysisPaused(at audioTime: TimeInterval)
    /// Catch up unanalyzed ranges from the saved recording (foreground return or stop).
    func catchUp(from recordingURL: URL, alreadyCoveredUntil: TimeInterval) async throws -> [TranscriptSegment]
    func finalize(from recordingURL: URL) async throws -> Transcript
}

@MainActor
protocol MinutesGenerating {
    func generate(from transcript: Transcript) async throws -> StructuredMinutes
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
    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes,
        mermaidSource: String,
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

    var phase: MeetingWorkflowPhase {
        state.phase
    }

    var recordingDuration: TimeInterval {
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

            // Transcription failures must not reverse an already-started recording.
            do {
                try await dependencies.transcriber.start { [weak self] segments in
                    guard let self else { return }
                    self.liveTranscript = segments
                    self.lastCompletedAudioEnd = TranscriptTimeline.lastCoveredEnd(in: segments)
                }
            } catch {
                // Keep recording state; surface diagnostic on live transcript banner via failed only if start fully aborts.
                // Spec: 转写错误不会删除或截断已有录音 — stay in recording with empty/partial transcript.
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

        let recordingDurationSnapshot = recordingDuration
        recordingStartedAt = nil

        let transcript: Transcript
        do {
            // Always attempt catch-up for any unanalyzed range before finalize.
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
            if !TranscriptTimeline.coversRecordingDuration(
                finalized.segments,
                duration: max(recordingDurationSnapshot, lastCompletedAudioEnd)
            ) {
                diagnosticNote = "最终逐字稿时间轴可能存在空洞，录音已完整保留。"
            }
            transcript = finalized
            liveTranscript = transcript.segments
            analysisPaused = false
        } catch {
            // Preserve recording evidence; do not invent a completed meeting.
            transition(
                to: .failed(
                    "\(error.localizedDescription)（原始录音已保留：\(recordingURL.lastPathComponent)）"
                )
            )
            return
        }

        do {
            transition(to: .generating)
            let minutes = try await dependencies.minutesGenerator.generate(from: transcript)
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
            transition(to: .completed(assets))
        } catch {
            transition(
                to: .failed(
                    "\(error.localizedDescription)（原始录音与逐字稿已保留：\(recordingURL.lastPathComponent)）"
                )
            )
        }
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
