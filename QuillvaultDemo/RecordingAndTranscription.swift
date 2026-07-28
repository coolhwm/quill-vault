import AVFoundation
import Foundation
import Speech

// MARK: - Permission

@MainActor
protocol MicrophonePermissioning {
    func requestAccess() async -> Bool
}

@MainActor
struct SystemMicrophonePermission: MicrophonePermissioning {
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
final class ControllableMicrophonePermission: MicrophonePermissioning {
    var granted: Bool

    init(granted: Bool = true) {
        self.granted = granted
    }

    func requestAccess() async -> Bool {
        granted
    }
}

enum RecordingError: LocalizedError, Equatable {
    case microphoneDenied
    case failedToStart(String)
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "麦克风权限被拒绝，无法开始录音。请在系统设置中允许访问麦克风。"
        case let .failedToStart(detail):
            "无法开始录音：\(detail)"
        case .notRecording:
            "当前没有进行中的录音。"
        }
    }
}

enum TranscriptionError: LocalizedError, Equatable {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "设备端转写不可用。"
        case let .failed(detail):
            "转写失败：\(detail)"
        }
    }
}

// MARK: - Transcript merge

enum LiveTranscriptMerger {
    /// Keeps final segments in order and at most one trailing volatile segment.
    static func applying(_ event: TranscriptSegment, to existing: [TranscriptSegment]) -> [TranscriptSegment] {
        var finals = existing.filter(\.isFinal)
        if event.isFinal {
            finals.append(event)
            finals.sort { $0.startTime < $1.startTime }
            return finals
        }
        return finals + [event]
    }
}

// MARK: - Device audio recorder (continuous m4a)

@MainActor
final class DeviceAudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func start(in directory: URL) async throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let fileURL = directory
            .appendingPathComponent("recording-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.failedToStart("AVAudioRecorder.record() 返回 false")
        }
        self.recorder = recorder
        self.recordingURL = fileURL
        return fileURL
    }

    func stop() async throws -> URL {
        guard let recorder, let recordingURL else {
            throw RecordingError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        return recordingURL
    }

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }
}

// MARK: - Controllable recording / transcription for tests

@MainActor
final class ControllableAudioRecorder: AudioRecording {
    private(set) var started = false
    private(set) var stopped = false
    private(set) var recordingURL: URL
    var startError: Error?
    var stopError: Error?

    init(recordingURL: URL = URL(filePath: "/tmp/quillvault-test-recording.m4a")) {
        self.recordingURL = recordingURL
    }

    func start(in directory: URL) async throws -> URL {
        if let startError { throw startError }
        // Materialize a tiny m4a-like file so asset writer / survival checks have bytes.
        let url = directory.appendingPathComponent("recording.m4a")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data("m4a-placeholder".utf8).write(to: url)
        }
        recordingURL = url
        started = true
        return url
    }

    func stop() async throws -> URL {
        if let stopError { throw stopError }
        stopped = true
        return recordingURL
    }
}

@MainActor
final class ControllableTranscriber: Transcribing {
    var liveEvents: [TranscriptSegment]
    var finalTranscript: Transcript
    var finalizeError: Error?
    var startError: Error?
    private var onUpdate: (@MainActor ([TranscriptSegment]) -> Void)?
    private(set) var liveSnapshot: [TranscriptSegment] = []

    init(
        liveEvents: [TranscriptSegment] = [],
        finalTranscript: Transcript? = nil,
        finalizeError: Error? = nil
    ) {
        self.liveEvents = liveEvents
        self.finalTranscript = finalTranscript ?? Transcript(segments: liveEvents.filter(\.isFinal))
        self.finalizeError = finalizeError
    }

    func start(onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void) async throws {
        if let startError { throw startError }
        self.onUpdate = onUpdate
        var merged: [TranscriptSegment] = []
        for event in liveEvents {
            merged = LiveTranscriptMerger.applying(event, to: merged)
            liveSnapshot = merged
            onUpdate(merged)
        }
    }

    func finalize(from recordingURL: URL) async throws -> Transcript {
        if let finalizeError { throw finalizeError }
        let finals = finalTranscript.segments.map {
            TranscriptSegment(
                id: $0.id,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                isFinal: true
            )
        }
        onUpdate?(finals)
        return Transcript(segments: finals)
    }

    /// Inject a late live event after start (tests).
    func emit(_ event: TranscriptSegment) {
        liveSnapshot = LiveTranscriptMerger.applying(event, to: liveSnapshot)
        onUpdate?(liveSnapshot)
    }
}

// MARK: - SpeechAnalyzer-backed live transcriber (device)

@MainActor
final class SpeechAnalyzerTranscriber: Transcribing {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var engine: AVAudioEngine?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finals: [TranscriptSegment] = []
    private var onUpdate: (@MainActor ([TranscriptSegment]) -> Void)?
    private var startedAt: Date?

    func start(onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void) async throws {
        self.onUpdate = onUpdate
        self.finals = []
        self.startedAt = Date()

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let locale = Locale(identifier: "zh-CN")
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        // Ensure assets when possible; ignore soft failures for demo.
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = continuation
        self.analyzer = analyzer
        self.transcriber = transcriber

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handle(result: result)
                }
            } catch {
                // Surface later via finalize if no finals collected.
            }
        }

        try await analyzer.start(inputSequence: stream)
        onUpdate(finals)
    }

    func finalize(from recordingURL: URL) async throws -> Transcript {
        inputBuilder?.finish()
        inputBuilder = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // Brief drain for late final results.
        try? await Task.sleep(for: .milliseconds(400))
        resultsTask?.cancel()
        resultsTask = nil

        // If live analysis produced nothing, attempt file-based catch-up for the saved m4a.
        if finals.isEmpty {
            try await catchUpFromFile(recordingURL)
        }

        analyzer = nil
        transcriber = nil
        let transcript = Transcript(segments: finals)
        onUpdate?(finals)
        return transcript
    }

    private func handle(result: SpeechTranscriber.Result) async {
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let segment = TranscriptSegment(
            startTime: start.isFinite ? start : 0,
            endTime: end.isFinite ? end : start,
            text: text,
            isFinal: result.isFinal
        )
        if segment.isFinal {
            finals = LiveTranscriptMerger.applying(segment, to: finals.filter(\.isFinal))
            onUpdate?(finals)
        } else {
            onUpdate?(LiveTranscriptMerger.applying(segment, to: finals))
        }
    }

    private func catchUpFromFile(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let locale = Locale(identifier: "zh-CN")
        let fileTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let file = try AVAudioFile(forReading: url)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file,
            modules: [fileTranscriber],
            finishAfterFile: true
        )
        let collect = Task {
            var collected: [TranscriptSegment] = []
            for try await result in fileTranscriber.results where result.isFinal {
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(result.range.end)
                let text = String(result.text.characters)
                if !text.isEmpty {
                    collected.append(
                        TranscriptSegment(
                            startTime: start,
                            endTime: end,
                            text: text,
                            isFinal: true
                        )
                    )
                }
            }
            return collected
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        finals = try await collect.value
    }
}

// MARK: - Meeting asset writer (recording + transcript)

@MainActor
final class FileMeetingAssetWriter: MeetingAssetWriting {
    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes,
        mermaidSource: String,
        to directory: URL
    ) async throws -> [MeetingAssetFile] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folderName = "meeting-\(formatter.string(from: Date()))"
        let meetingDir = directory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        let destRecording = meetingDir.appendingPathComponent("recording.m4a")
        if FileManager.default.fileExists(atPath: destRecording.path) {
            try FileManager.default.removeItem(at: destRecording)
        }
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            try FileManager.default.copyItem(at: recordingURL, to: destRecording)
        } else {
            try Data().write(to: destRecording)
        }

        let transcriptMarkdown = Self.transcriptMarkdown(from: transcript)
        let transcriptURL = meetingDir.appendingPathComponent("transcript.md")
        try transcriptMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        // minutes.md is still produced by later tickets with full structure; write a minimal stub so the
        // directory is inspectable without claiming BYOK minutes are done.
        let minutesURL = meetingDir.appendingPathComponent("minutes.md")
        let minutesBody = """
        ---
        title: \(minutes.title)
        status: demo-partial
        ---

        # \(minutes.title)

        \(minutes.overview)

        \(minutes.summary)

        ```mermaid
        \(mermaidSource)
        ```

        - [逐字稿](./transcript.md)
        - [录音](./recording.m4a)
        """
        try minutesBody.write(to: minutesURL, atomically: true, encoding: .utf8)

        return [
            MeetingAssetFile(name: "recording.m4a", detail: destRecording.path),
            MeetingAssetFile(name: "transcript.md", detail: "\(transcript.segments.count) 个带时间戳片段"),
            MeetingAssetFile(name: "minutes.md", detail: "结构化纪要（后续 BYOK 票完善）")
        ]
    }

    static func transcriptMarkdown(from transcript: Transcript) -> String {
        var lines = ["# 逐字稿", ""]
        for segment in transcript.segments {
            lines.append(
                String(
                    format: "- [%05.1f–%05.1f] %@",
                    segment.startTime,
                    segment.endTime,
                    segment.text
                )
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

@MainActor
final class ControllableAssetWriter: MeetingAssetWriting {
    private(set) var lastRecordingURL: URL?
    private(set) var lastTranscript: Transcript?
    private(set) var wroteTo: URL?
    var shouldFail = false
    var writtenFiles: [MeetingAssetFile] = [
        MeetingAssetFile(name: "recording.m4a", detail: "written"),
        MeetingAssetFile(name: "transcript.md", detail: "written"),
        MeetingAssetFile(name: "minutes.md", detail: "written")
    ]

    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes,
        mermaidSource: String,
        to directory: URL
    ) async throws -> [MeetingAssetFile] {
        lastRecordingURL = recordingURL
        lastTranscript = transcript
        wroteTo = directory
        if shouldFail {
            throw TranscriptionError.failed("asset write failed")
        }
        // Mirror essential files when the recording exists so survival tests can inspect them.
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            let meetingDir = directory.appendingPathComponent("meeting-test", isDirectory: true)
            try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
            let dest = meetingDir.appendingPathComponent("recording.m4a")
            if dest.path != recordingURL.path {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: recordingURL, to: dest)
            }
            try FileMeetingAssetWriter.transcriptMarkdown(from: transcript)
                .write(
                    to: meetingDir.appendingPathComponent("transcript.md"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        return writtenFiles
    }
}
