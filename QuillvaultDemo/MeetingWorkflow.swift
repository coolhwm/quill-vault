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
    func start() async throws -> [TranscriptSegment]
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
}

@MainActor
@Observable
final class MeetingWorkflow {
    private let dependencies: MeetingWorkflowDependencies
    private var authorizedDirectory: URL?

    private(set) var state: MeetingWorkflowState = .setup
    private(set) var liveTranscript: [TranscriptSegment] = []
    private(set) var phaseHistory: [MeetingWorkflowPhase] = [.setup]

    var phase: MeetingWorkflowPhase {
        state.phase
    }

    init(dependencies: MeetingWorkflowDependencies) {
        self.dependencies = dependencies
    }

    func startFaceToFaceSession() async {
        guard phase == .setup || phase == .failed else { return }

        do {
            guard await dependencies.credentialChecker.hasBYOKCredential() else {
                throw DemoWorkflowError.missingCredential
            }
            let directory = try await dependencies.directoryAccess.authorizedDirectory()
            _ = try await dependencies.audioRecorder.start(in: directory)
            let initialTranscript = try await dependencies.transcriber.start()
            self.authorizedDirectory = directory
            liveTranscript = initialTranscript
            transition(to: .recording)
        } catch {
            transition(to: .failed(error.localizedDescription))
        }
    }

    func finishFaceToFaceSession() async {
        guard phase == .recording, let directory = authorizedDirectory else { return }

        do {
            transition(to: .finalizing)
            let recordingURL = try await dependencies.audioRecorder.stop()
            let transcript = try await dependencies.transcriber.finalize(from: recordingURL)
            liveTranscript = transcript.segments

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
            transition(to: .completed(assets))
        } catch {
            transition(to: .failed(error.localizedDescription))
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
            "受控凭据替身未准备好"
        case .rejectedDemoResponse:
            "BYOK 替身返回了可诊断的失败；录音与逐字稿仍保留"
        }
    }
}
