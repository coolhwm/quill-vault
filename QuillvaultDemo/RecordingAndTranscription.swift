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

// MARK: - Device audio recorder (continuous m4a — sole mic owner)

@MainActor
final class DeviceAudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func start(in directory: URL) async throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)

        // Write directly into a meeting asset directory so mid-session kills still leave a coherent folder.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let meetingDir = directory.appendingPathComponent(
            "meeting-\(formatter.string(from: Date()))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let fileURL = meetingDir.appendingPathComponent("recording.m4a")

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
    /// When zero, workflow coverage falls back to last completed transcript end.
    var simulatedCurrentTime: TimeInterval = 0
    var startError: Error?
    var stopError: Error?

    init(recordingURL: URL = URL(filePath: "/tmp/quillvault-test-recording.m4a")) {
        self.recordingURL = recordingURL
    }

    var currentTime: TimeInterval {
        guard started else { return 0 }
        return simulatedCurrentTime
    }

    func start(in directory: URL) async throws -> URL {
        if let startError { throw startError }
        let meetingDir = directory.appendingPathComponent("meeting-test", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let url = meetingDir.appendingPathComponent("recording.m4a")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data("m4a-placeholder".utf8).write(to: url)
        }
        recordingURL = url
        started = true
        stopped = false
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
    var catchUpError: Error?
    /// Segments produced only by catch-up (background gap fill).
    var catchUpSegments: [TranscriptSegment] = []
    private(set) var pausedAt: TimeInterval?
    private(set) var catchUpCalls: [(URL, TimeInterval)] = []
    private var onUpdate: (@MainActor ([TranscriptSegment]) -> Void)?
    private(set) var liveSnapshot: [TranscriptSegment] = []

    init(
        liveEvents: [TranscriptSegment] = [],
        finalTranscript: Transcript? = nil,
        finalizeError: Error? = nil,
        catchUpSegments: [TranscriptSegment] = []
    ) {
        self.liveEvents = liveEvents
        self.finalTranscript = finalTranscript ?? Transcript(segments: liveEvents.filter(\.isFinal))
        self.finalizeError = finalizeError
        self.catchUpSegments = catchUpSegments
    }

    func start(
        recordingURL: URL,
        onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void
    ) async throws {
        if let startError { throw startError }
        self.onUpdate = onUpdate
        var merged: [TranscriptSegment] = []
        for event in liveEvents {
            merged = LiveTranscriptMerger.applying(event, to: merged)
            liveSnapshot = merged
            onUpdate(merged)
        }
    }

    func noteAnalysisPaused(at audioTime: TimeInterval) {
        pausedAt = audioTime
    }

    func catchUp(
        from recordingURL: URL,
        alreadyCoveredUntil: TimeInterval
    ) async throws -> [TranscriptSegment] {
        catchUpCalls.append((recordingURL, alreadyCoveredUntil))
        if let catchUpError { throw catchUpError }
        let segments = catchUpSegments.filter { $0.startTime >= alreadyCoveredUntil - 0.05 }
        if !segments.isEmpty {
            var merged = liveSnapshot
            for segment in segments {
                merged = LiveTranscriptMerger.applying(
                    TranscriptSegment(
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        text: segment.text,
                        isFinal: true
                    ),
                    to: merged
                )
            }
            liveSnapshot = merged
            onUpdate?(merged)
        }
        return segments
    }

    func finalize(from recordingURL: URL) async throws -> Transcript {
        if let finalizeError { throw finalizeError }
        let finals = TranscriptTimeline.mergeFinals(finalTranscript.segments + catchUpSegments)
        onUpdate?(finals)
        return Transcript(segments: finals)
    }

    /// Inject a late live event after start (tests).
    func emit(_ event: TranscriptSegment) {
        liveSnapshot = LiveTranscriptMerger.applying(event, to: liveSnapshot)
        onUpdate?(liveSnapshot)
    }
}

// MARK: - SpeechAnalyzer transcriber (file-based; does not open a second mic)

/// Sole mic owner is `DeviceAudioRecorder`. This type only analyzes the saved m4a so
/// recording integrity is never contested by a parallel AVAudioEngine input tap.
@MainActor
final class SpeechAnalyzerTranscriber: Transcribing {
    private var finals: [TranscriptSegment] = []
    private var onUpdate: (@MainActor ([TranscriptSegment]) -> Void)?
    private var analysisPausedAt: TimeInterval?
    private var activeRecordingURL: URL?
    private var pollTask: Task<Void, Never>?

    func start(
        recordingURL: URL,
        onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void
    ) async throws {
        self.onUpdate = onUpdate
        self.finals = []
        self.analysisPausedAt = nil
        self.activeRecordingURL = recordingURL

        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let locale = Locale(identifier: "zh-CN")
        let probe = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try? await request.downloadAndInstall()
        }

        // Best-effort live progress by re-reading the growing recording file.
        // Never installs an input tap — audio continuity owns the mic.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, let url = self.activeRecordingURL else { continue }
                if self.analysisPausedAt != nil { continue }
                let covered = TranscriptTimeline.lastCoveredEnd(in: self.finals)
                if let filled = try? await self.analyzeFile(url, after: covered), !filled.isEmpty {
                    self.finals = TranscriptTimeline.mergeFinals(self.finals + filled)
                    self.onUpdate?(self.finals)
                }
            }
        }
        onUpdate(finals)
    }

    func noteAnalysisPaused(at audioTime: TimeInterval) {
        analysisPausedAt = audioTime
    }

    func catchUp(
        from recordingURL: URL,
        alreadyCoveredUntil: TimeInterval
    ) async throws -> [TranscriptSegment] {
        let filled = try await analyzeFile(recordingURL, after: alreadyCoveredUntil)
        if !filled.isEmpty {
            finals = TranscriptTimeline.mergeFinals(finals + filled)
            onUpdate?(finals)
        }
        analysisPausedAt = nil
        return filled
    }

    func finalize(from recordingURL: URL) async throws -> Transcript {
        pollTask?.cancel()
        pollTask = nil
        activeRecordingURL = nil

        let covered = TranscriptTimeline.lastCoveredEnd(in: finals)
        let filled = try await analyzeFile(recordingURL, after: covered)
        finals = TranscriptTimeline.mergeFinals(finals + filled)
        let transcript = Transcript(segments: finals)
        onUpdate?(finals)
        return transcript
    }

    private func analyzeFile(_ url: URL, after alreadyCoveredUntil: TimeInterval) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // Growing files may briefly be unreadable while the recorder flushes.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return [] }

        let locale = Locale(identifier: "zh-CN")
        let fileTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return []
        }
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
                if text.isEmpty { continue }
                if end <= alreadyCoveredUntil + 0.05 { continue }
                let clippedStart = max(start, alreadyCoveredUntil)
                collected.append(
                    TranscriptSegment(
                        startTime: clippedStart,
                        endTime: end,
                        text: text,
                        isFinal: true
                    )
                )
            }
            return collected
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value
    }
}

// MARK: - Meeting asset writer (recording + transcript)

@MainActor
final class FileMeetingAssetWriter: MeetingAssetWriting {
    private var lastMeetingDir: URL?

    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes?,
        mermaidSource: String?,
        to directory: URL
    ) async throws -> [MeetingAssetFile] {
        // Prefer the meeting folder created at record start (`…/meeting-*/recording.m4a`).
        let parent = recordingURL.deletingLastPathComponent()
        let meetingDir: URL
        if parent.lastPathComponent.hasPrefix("meeting-") {
            meetingDir = parent
        } else if let lastMeetingDir,
                  FileManager.default.fileExists(atPath: lastMeetingDir.path)
        {
            meetingDir = lastMeetingDir
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            meetingDir = directory.appendingPathComponent(
                "meeting-\(formatter.string(from: Date()))",
                isDirectory: true
            )
        }
        lastMeetingDir = meetingDir
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        let destRecording = meetingDir.appendingPathComponent("recording.m4a")
        if recordingURL.standardizedFileURL == destRecording.standardizedFileURL {
            // Already the authoritative meeting recording path.
            guard FileManager.default.fileExists(atPath: destRecording.path) else {
                throw RecordingError.failedToStart("会议目录中缺少 recording.m4a")
            }
        } else if !FileManager.default.fileExists(atPath: destRecording.path) {
            guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                throw RecordingError.failedToStart("源录音不存在，拒绝写入空 recording.m4a")
            }
            try FileManager.default.copyItem(at: recordingURL, to: destRecording)
        }
        // Refuse zero-byte evidence files.
        let attrs = try FileManager.default.attributesOfItem(atPath: destRecording.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw RecordingError.failedToStart("recording.m4a 为空，拒绝作为会议资产")
        }

        let transcriptURL = meetingDir.appendingPathComponent("transcript.md")
        try Self.transcriptMarkdown(from: transcript)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        var files = [
            MeetingAssetFile(name: "recording.m4a", detail: destRecording.path),
            MeetingAssetFile(name: "transcript.md", detail: "\(transcript.segments.count) 个带时间戳片段")
        ]

        if let minutes, let mermaidSource {
            let minutesURL = meetingDir.appendingPathComponent("minutes.md")
            let minutesBody = """
            ---
            title: "\(minutes.title.replacingOccurrences(of: "\"", with: "'"))"
            status: byok
            generated_by: quillvault-demo
            ---

            # \(minutes.title)

            ## 总览
            \(minutes.overview)

            ## 摘要
            \(minutes.summary)

            ## 章节
            \(minutes.chapters.map { "- [\($0.startTime)-\($0.endTime)] \($0.title)：\($0.summary)" }.joined(separator: "\n"))

            ## 决策
            \(minutes.decisions.map { "- \($0.statement)（\($0.reason)；依据：\($0.evidence)）" }.joined(separator: "\n"))

            ## 行动项
            \(minutes.actionItems.map { "- \($0.owner) · \($0.task) · \($0.deadline)\n  依据：\($0.evidence)" }.joined(separator: "\n"))

            ## 风险
            \(minutes.risks.map { "- \($0)" }.joined(separator: "\n"))

            ## 未决问题
            \(minutes.unresolvedQuestions.map { "- \($0)" }.joined(separator: "\n"))

            ## 核心观点图
            ```mermaid
            \(mermaidSource)
            ```

            ## 来源
            - [transcript.md](./transcript.md)
            - [recording.m4a](./recording.m4a)
            """
            try AtomicFileWriter.writeAtomically(minutesBody, to: minutesURL)
            files.append(MeetingAssetFile(name: "minutes.md", detail: minutesURL.path))
        } else {
            // Ensure no partial minutes.md is treated as success.
            let minutesURL = meetingDir.appendingPathComponent("minutes.md")
            if FileManager.default.fileExists(atPath: minutesURL.path) {
                try FileManager.default.removeItem(at: minutesURL)
            }
        }

        return files
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
    private(set) var lastWroteMinutes = false
    private(set) var writeCallCount = 0
    var shouldFail = false

    func write(
        recordingURL: URL,
        transcript: Transcript,
        minutes: StructuredMinutes?,
        mermaidSource: String?,
        to directory: URL
    ) async throws -> [MeetingAssetFile] {
        writeCallCount += 1
        lastRecordingURL = recordingURL
        lastTranscript = transcript
        wroteTo = directory
        lastWroteMinutes = minutes != nil
        if shouldFail {
            throw TranscriptionError.failed("asset write failed")
        }
        let meetingDir = directory.appendingPathComponent("meeting-test", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            let dest = meetingDir.appendingPathComponent("recording.m4a")
            if dest.path != recordingURL.path {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: recordingURL, to: dest)
            }
        }
        try FileMeetingAssetWriter.transcriptMarkdown(from: transcript)
            .write(
                to: meetingDir.appendingPathComponent("transcript.md"),
                atomically: true,
                encoding: .utf8
            )
        let minutesURL = meetingDir.appendingPathComponent("minutes.md")
        if let minutes {
            try "title: \(minutes.title)".write(to: minutesURL, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: minutesURL.path) {
            try FileManager.default.removeItem(at: minutesURL)
        }

        var files = [
            MeetingAssetFile(name: "recording.m4a", detail: "written"),
            MeetingAssetFile(name: "transcript.md", detail: "written")
        ]
        if minutes != nil {
            files.append(MeetingAssetFile(name: "minutes.md", detail: "written"))
        }
        return files
    }
}
