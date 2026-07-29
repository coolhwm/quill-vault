@preconcurrency import AVFoundation
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

enum ExistingMeetingImportError: LocalizedError, Equatable {
    case missingRecording
    case missingTranscript
    case unreadableTranscript

    var errorDescription: String? {
        switch self {
        case .missingRecording:
            "所选会议目录缺少 recording.m4a。"
        case .missingTranscript:
            "所选会议目录缺少 transcript.md。"
        case .unreadableTranscript:
            "transcript.md 中没有可读取的带时间戳逐字稿片段。"
        }
    }
}

enum ExistingTranscriptParser {
    static func parse(markdown: String) throws -> Transcript {
        let expression = try NSRegularExpression(
            pattern: #"(?m)^\s*-\s*\[\s*(\d+(?:\.\d+)?)\s*[–-]\s*(\d+(?:\.\d+)?)\s*\]\s+(.+?)\s*$"#
        )
        let fullRange = NSRange(markdown.startIndex..., in: markdown)
        let segments: [TranscriptSegment] = expression.matches(
            in: markdown,
            range: fullRange
        ).compactMap { match -> TranscriptSegment? in
            guard let startRange = Range(match.range(at: 1), in: markdown),
                  let endRange = Range(match.range(at: 2), in: markdown),
                  let textRange = Range(match.range(at: 3), in: markdown),
                  let start = TimeInterval(String(markdown[startRange])),
                  let end = TimeInterval(String(markdown[endRange])),
                  start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start
            else {
                return nil
            }
            let text = markdown[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                startTime: start,
                endTime: end,
                text: text,
                isFinal: true
            )
        }
        let normalized = TranscriptTimeline.mergeFinals(segments)
        guard !normalized.isEmpty else {
            throw ExistingMeetingImportError.unreadableTranscript
        }
        return Transcript(segments: normalized)
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
protocol LiveAudioBufferSource: AnyObject {
    func setAudioBufferHandler(_ handler: (@Sendable (SendableAudioBuffer) -> Void)?)
}

struct SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

final class DeviceAudioCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var handler: (@Sendable (SendableAudioBuffer) -> Void)?
    private var capturedFrames: AVAudioFramePosition = 0
    private var writeError: Error?
    private let sampleRate: Double

    init(audioFile: AVAudioFile, sampleRate: Double) {
        self.audioFile = audioFile
        self.sampleRate = sampleRate
    }

    func setHandler(_ handler: (@Sendable (SendableAudioBuffer) -> Void)?) {
        lock.withLock {
            self.handler = handler
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        let copiedBuffer: AVAudioPCMBuffer?
        let currentHandler: (@Sendable (SendableAudioBuffer) -> Void)?
        lock.lock()
        do {
            try audioFile?.write(from: buffer)
            capturedFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = error
        }
        currentHandler = handler
        copiedBuffer = currentHandler == nil ? nil : Self.copy(buffer)
        lock.unlock()
        if let copiedBuffer {
            currentHandler?(SendableAudioBuffer(value: copiedBuffer))
        }
    }

    nonisolated func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            self?.receive(buffer)
        }
    }

    var duration: TimeInterval {
        lock.withLock {
            guard sampleRate > 0 else { return 0 }
            return Double(capturedFrames) / sampleRate
        }
    }

    var failureDescription: String? {
        lock.withLock {
            writeError?.localizedDescription
        }
    }

    func close() {
        lock.withLock {
            handler = nil
            audioFile = nil
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                continue
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return destination
    }
}

@MainActor
final class DeviceAudioRecorder: AudioRecording, LiveAudioBufferSource {
    private var engine: AVAudioEngine?
    private var captureSink: DeviceAudioCaptureSink?
    private var recordingURL: URL?
    private var lastDuration: TimeInterval = 0

    func start(in directory: URL) async throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
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

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.failedToStart("麦克风没有可用的音频格式")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        let sink = DeviceAudioCaptureSink(audioFile: file, sampleRate: inputFormat.sampleRate)
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat,
            block: sink.makeTapBlock()
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.close()
            throw RecordingError.failedToStart(error.localizedDescription)
        }
        self.engine = engine
        self.captureSink = sink
        self.recordingURL = fileURL
        self.lastDuration = 0
        return fileURL
    }

    func stop() async throws -> URL {
        guard let engine, let captureSink, let recordingURL else {
            throw RecordingError.notRecording
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lastDuration = captureSink.duration
        let failureDescription = captureSink.failureDescription
        captureSink.close()
        self.engine = nil
        self.captureSink = nil
        if let failureDescription {
            throw RecordingError.failedToStart("写入 M4A 失败：\(failureDescription)")
        }
        guard lastDuration > 0 else {
            throw RecordingError.failedToStart("录音文件没有捕获到音频帧")
        }
        return recordingURL
    }

    var currentTime: TimeInterval {
        captureSink?.duration ?? lastDuration
    }

    func setAudioBufferHandler(_ handler: (@Sendable (SendableAudioBuffer) -> Void)?) {
        captureSink?.setHandler(handler)
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
final class ControllableAudioBufferSource: LiveAudioBufferSource {
    private var handler: (@Sendable (SendableAudioBuffer) -> Void)?

    var hasHandler: Bool {
        handler != nil
    }

    func setAudioBufferHandler(_ handler: (@Sendable (SendableAudioBuffer) -> Void)?) {
        self.handler = handler
    }

    func emitTestBuffer() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        handler?(SendableAudioBuffer(value: buffer))
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

// MARK: - SpeechAnalyzer transcriber (one live stream from the recorder's mic buffers)

@MainActor
protocol SpeechAnalysisSessioning: AnyObject {
    func start(onResult: @escaping @MainActor (TranscriptSegment) -> Void) async throws
    func receive(_ buffer: AVAudioPCMBuffer)
    func finish() async throws
}

@MainActor
final class ControllableSpeechAnalysisSession: SpeechAnalysisSessioning {
    private var onResult: (@MainActor (TranscriptSegment) -> Void)?
    private(set) var startCount = 0
    private(set) var receivedBufferCount = 0
    private(set) var finishCount = 0
    var resultForReceivedBuffer: ((Int) -> TranscriptSegment)?
    private var sessionBufferIndex = 0

    func start(onResult: @escaping @MainActor (TranscriptSegment) -> Void) async throws {
        startCount += 1
        sessionBufferIndex = 0
        self.onResult = onResult
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        receivedBufferCount += 1
        if let result = resultForReceivedBuffer?(sessionBufferIndex) {
            onResult?(result)
        }
        sessionBufferIndex += 1
    }

    func finish() async throws {
        finishCount += 1
    }

    func emit(_ segment: TranscriptSegment) {
        onResult?(segment)
    }
}

@MainActor
final class DeviceSpeechAnalysisSession: SpeechAnalysisSessioning {
    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func start(onResult: @escaping @MainActor (TranscriptSegment) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let requestedLocale = Locale(identifier: "zh-CN")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.failed("设备不支持简体中文语音模型")
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscriptionError.failed("无法取得 SpeechAnalyzer 兼容音频格式")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.analyzerFormat = analyzerFormat
        self.inputContinuation = continuation
        self.resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = CMTimeGetSeconds(result.range.end)
                    let text = String(result.text.characters)
                    guard !text.isEmpty, start.isFinite, end.isFinite, end >= start else {
                        continue
                    }
                    onResult(
                        TranscriptSegment(
                            startTime: start,
                            endTime: end,
                            text: text,
                            isFinal: result.isFinal
                        )
                    )
                }
            } catch {
                // finish() owns lifecycle errors; result termination itself is not fatal.
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        do {
            let converted = try convertedBuffer(buffer)
            inputContinuation?.yield(AnalyzerInput(buffer: converted))
        } catch {
            // A later buffer may recover after an audio-route format change.
            converter = nil
        }
    }

    func finish() async throws {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        converter = nil
    }

    private func convertedBuffer(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let analyzerFormat else {
            throw TranscriptionError.failed("SpeechAnalyzer 尚未准备完成")
        }
        if input.format == analyzerFormat {
            return input
        }
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: analyzerFormat)
        }
        guard let converter else {
            throw TranscriptionError.failed("无法创建音频格式转换器")
        }
        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: capacity
        ) else {
            throw TranscriptionError.failed("无法分配转写音频缓冲区")
        }
        let converterInput = ConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if converterInput.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            converterInput.supplied = true
            inputStatus.pointee = .haveData
            return converterInput.buffer
        }
        if let conversionError {
            throw conversionError
        }
        guard status == .haveData || status == .inputRanDry else {
            throw TranscriptionError.failed("音频格式转换失败：\(status.rawValue)")
        }
        return output
    }
}

@MainActor
final class SpeechAnalyzerTranscriber: Transcribing {
    private var finals: [TranscriptSegment] = []
    private var liveSnapshot: [TranscriptSegment] = []
    private var onUpdate: (@MainActor ([TranscriptSegment]) -> Void)?
    private let audioSource: any LiveAudioBufferSource
    private let analysisSession: any SpeechAnalysisSessioning
    private var timelineOffset: TimeInterval = 0
    private var pausedAt: TimeInterval?
    private var isPaused = false
    private var pendingBuffers: [SendableAudioBuffer] = []

    init(
        audioSource: any LiveAudioBufferSource,
        analysisSession: any SpeechAnalysisSessioning = DeviceSpeechAnalysisSession()
    ) {
        self.audioSource = audioSource
        self.analysisSession = analysisSession
    }

    func start(
        recordingURL: URL,
        onUpdate: @escaping @MainActor ([TranscriptSegment]) -> Void
    ) async throws {
        self.onUpdate = onUpdate
        self.finals = []
        self.liveSnapshot = []
        self.timelineOffset = 0
        self.pausedAt = nil
        self.isPaused = false
        self.pendingBuffers = []
        try await startAnalysisSession(at: 0)
        audioSource.setAudioBufferHandler { [weak self] buffer in
            Task { @MainActor [weak self] in
                self?.route(buffer)
            }
        }
        onUpdate(finals)
    }

    func noteAnalysisPaused(at audioTime: TimeInterval) {
        guard !isPaused else { return }
        pausedAt = audioTime
        isPaused = true
    }

    func catchUp(
        from recordingURL: URL,
        alreadyCoveredUntil: TimeInterval
    ) async throws -> [TranscriptSegment] {
        guard isPaused else { return [] }

        // SpeechAnalyzer itself may stop producing results while the app is backgrounded.
        // End that one session first, then replay the recorder's buffered PCM into a new,
        // non-overlapping session whose local zero maps to the original audio timeline.
        try await analysisSession.finish()
        let replayOffset = pausedAt ?? alreadyCoveredUntil
        try await startAnalysisSession(at: replayOffset)

        // No await in this drain: buffer-routing tasks cannot interleave between the final
        // empty check and clearing isPaused, so every background buffer is replayed once.
        while !pendingBuffers.isEmpty {
            let batch = pendingBuffers
            pendingBuffers.removeAll(keepingCapacity: true)
            for buffer in batch {
                analysisSession.receive(buffer.value)
            }
        }
        isPaused = false
        pausedAt = nil

        return finals.filter {
            $0.isFinal && $0.endTime > alreadyCoveredUntil + 0.001
        }
    }

    func finalize(from recordingURL: URL) async throws -> Transcript {
        audioSource.setAudioBufferHandler(nil)
        if isPaused {
            try await analysisSession.finish()
            try await startAnalysisSession(at: pausedAt ?? TranscriptTimeline.lastCoveredEnd(in: finals))
            while !pendingBuffers.isEmpty {
                let batch = pendingBuffers
                pendingBuffers.removeAll(keepingCapacity: true)
                for buffer in batch {
                    analysisSession.receive(buffer.value)
                }
            }
            isPaused = false
            pausedAt = nil
        }
        try await analysisSession.finish()
        let transcript = Transcript(segments: finals)
        onUpdate?(finals)
        return transcript
    }

    private func startAnalysisSession(at offset: TimeInterval) async throws {
        timelineOffset = offset
        try await analysisSession.start { [weak self] segment in
            guard let self else { return }
            let adjusted = TranscriptSegment(
                startTime: segment.startTime + self.timelineOffset,
                endTime: segment.endTime + self.timelineOffset,
                text: segment.text,
                isFinal: segment.isFinal
            )
            self.liveSnapshot = LiveTranscriptMerger.applying(adjusted, to: self.liveSnapshot)
            if adjusted.isFinal {
                self.finals = TranscriptTimeline.mergeFinals(self.finals + [adjusted])
            }
            self.onUpdate?(self.liveSnapshot)
        }
    }

    private func route(_ buffer: SendableAudioBuffer) {
        if isPaused {
            pendingBuffers.append(buffer)
        } else {
            analysisSession.receive(buffer.value)
        }
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
        let existingTranscript = parent.appendingPathComponent("transcript.md")
        if parent.lastPathComponent.hasPrefix("meeting-")
            || FileManager.default.fileExists(atPath: existingTranscript.path)
        {
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
