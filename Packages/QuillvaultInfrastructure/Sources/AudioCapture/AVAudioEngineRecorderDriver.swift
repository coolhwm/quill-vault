import AVFAudio
import AudioToolbox
import Domain
import Foundation

final class AVAudioEngineRecorderDriver: AudioRecorderDriving, @unchecked Sendable {
  private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var writeError: (any Error)?
    private var didWrite = false
    let continuation: AsyncStream<AudioFrame>.Continuation
    let stream: AsyncStream<AudioFrame>

    init() {
      var capturedContinuation: AsyncStream<AudioFrame>.Continuation?
      stream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
        capturedContinuation = $0
      }
      continuation = capturedContinuation!
    }

    func recordWriteSuccess() {
      lock.withLock {
        didWrite = true
      }
    }

    func recordWriteFailure(_ error: any Error) {
      lock.withLock {
        writeError = error
      }
    }

    func status() -> (didWrite: Bool, error: (any Error)?) {
      lock.withLock {
        (didWrite, writeError)
      }
    }
  }

  private let firstWriteTimeout: Duration
  private let pollingInterval: Duration
  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var state: CaptureState?

  init(
    firstWriteTimeout: Duration = .milliseconds(800),
    pollingInterval: Duration = .milliseconds(10)
  ) {
    self.firstWriteTimeout = firstWriteTimeout
    self.pollingInterval = pollingInterval
  }

  func start(at url: URL) async throws -> Date {
    guard engine == nil else {
      throw RecordingError.alreadyRecording
    }
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw RecordingError.captureCouldNotStart
    }

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .record,
        mode: .measurement,
        options: [.allowBluetoothHFP]
      )
      try session.setActive(true)
    #endif

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      deactivateAudioSession()
      throw RecordingError.captureCouldNotStart
    }

    var settings = inputFormat.settings
    settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    settings[AVEncoderBitRateKey] = 64_000
    settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
    let audioFile = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: inputFormat.commonFormat,
      interleaved: inputFormat.isInterleaved
    )
    let state = CaptureState()
    var framePosition: AVAudioFramePosition = 0

    input.installTap(
      onBus: 0,
      bufferSize: 2_048,
      format: inputFormat
    ) { buffer, _ in
      do {
        try audioFile.write(from: buffer)
        state.recordWriteSuccess()
      } catch {
        state.recordWriteFailure(error)
        return
      }

      if let frame = Self.copyFrame(
        buffer,
        startFrame: framePosition
      ) {
        state.continuation.yield(frame)
      }
      framePosition += AVAudioFramePosition(buffer.frameLength)
    }

    do {
      engine.prepare()
      let startedAt = Date()
      try engine.start()
      self.engine = engine
      self.audioFile = audioFile
      self.state = state
      try await waitForFirstWrite(state)
      return startedAt
    } catch is CancellationError {
      stop()
      throw CancellationError()
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
      state.continuation.finish()
      self.engine = nil
      self.audioFile = nil
      self.state = nil
      deactivateAudioSession()
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  func frames() -> AsyncStream<AudioFrame> {
    state?.stream ?? AsyncStream { $0.finish() }
  }

  func stop() {
    guard let engine else {
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    state?.continuation.finish()
    self.engine = nil
    audioFile = nil
    state = nil
    deactivateAudioSession()
  }

  private func waitForFirstWrite(_ state: CaptureState) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: firstWriteTimeout)
    while clock.now < deadline {
      try Task.checkCancellation()
      let status = state.status()
      if status.error != nil {
        throw RecordingError.recordingWriteFailed
      }
      if status.didWrite {
        return
      }
      try await Task.sleep(for: pollingInterval)
    }
    throw RecordingError.recordingWriteFailed
  }

  private static func copyFrame(
    _ buffer: AVAudioPCMBuffer,
    startFrame: AVAudioFramePosition
  ) -> AudioFrame? {
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    let sampleRate = buffer.format.sampleRate
    guard
      frameCount > 0,
      channelCount > 0,
      sampleRate > 0,
      let channels = buffer.floatChannelData
    else {
      return nil
    }

    var interleaved = [Float](
      repeating: 0,
      count: frameCount * channelCount
    )
    for frameIndex in 0..<frameCount {
      for channelIndex in 0..<channelCount {
        interleaved[frameIndex * channelCount + channelIndex] =
          channels[channelIndex][frameIndex]
      }
    }
    return interleaved.withUnsafeBytes {
      AudioFrame(
        samples: Data($0),
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCount: frameCount,
        startSeconds: Double(startFrame) / sampleRate
      )
    }
  }

  private func deactivateAudioSession() {
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    #endif
  }
}
