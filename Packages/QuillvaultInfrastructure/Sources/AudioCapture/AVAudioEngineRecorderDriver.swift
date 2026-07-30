import AVFAudio
import AudioToolbox
import Domain
import Foundation

final class AVAudioEngineRecorderDriver: AudioRecorderDriving, @unchecked Sendable {
  private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var framePosition: AVAudioFramePosition = 0
    let writeMonitor = AudioCaptureWriteMonitor()
    let continuation: AsyncStream<AudioFrame>.Continuation
    let stream: AsyncStream<AudioFrame>
    let eventContinuation: AsyncStream<RecordingCaptureEvent>.Continuation
    let eventStream: AsyncStream<RecordingCaptureEvent>

    init() {
      var capturedContinuation: AsyncStream<AudioFrame>.Continuation?
      stream = AsyncStream(bufferingPolicy: .bufferingNewest(64)) {
        capturedContinuation = $0
      }
      continuation = capturedContinuation!

      var capturedEventContinuation: AsyncStream<RecordingCaptureEvent>.Continuation?
      eventStream = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
        capturedEventContinuation = $0
      }
      eventContinuation = capturedEventContinuation!
    }

    func recordWriteSuccess() {
      writeMonitor.recordWriteSuccess()
    }

    func recordWriteFailure(_ error: any Error) {
      writeMonitor.recordWriteFailure(error)
    }

    func status() -> (didWrite: Bool, error: (any Error)?) {
      writeMonitor.status()
    }

    func takeFramePosition(
      advancingBy frameCount: AVAudioFrameCount
    ) -> AVAudioFramePosition {
      lock.withLock {
        let position = framePosition
        framePosition += AVAudioFramePosition(frameCount)
        return position
      }
    }
  }

  private let firstWriteTimeout: Duration
  private let pollingInterval: Duration
  private let now: @Sendable () -> Date
  private let writerFactory: @Sendable (URL, AVAudioFormat) throws -> any FragmentedAudioWriting
  private let lifecycleLock = NSRecursiveLock()
  private var engine: AVAudioEngine?
  private var writer: (any FragmentedAudioWriting)?
  private var state: CaptureState?
  private var terminalStopError: RecordingError?
  #if os(iOS)
    private var lifecycleObservers: [NSObjectProtocol] = []
  #endif

  init(
    firstWriteTimeout: Duration = .milliseconds(800),
    pollingInterval: Duration = .milliseconds(10),
    now: @escaping @Sendable () -> Date = Date.init,
    writerFactory:
      @escaping @Sendable (URL, AVAudioFormat) throws ->
      any FragmentedAudioWriting = {
        try FragmentedM4AWriter(outputURL: $0, sourceFormat: $1)
      }
  ) {
    self.firstWriteTimeout = firstWriteTimeout
    self.pollingInterval = pollingInterval
    self.now = now
    self.writerFactory = writerFactory
  }

  func start(at url: URL) async throws -> Date {
    guard engine == nil else {
      throw RecordingError.alreadyRecording
    }
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw RecordingError.captureCouldNotStart
    }

    #if os(iOS)
      try configureAndActivateAudioSession()
    #endif

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      deactivateAudioSession()
      throw RecordingError.captureCouldNotStart
    }

    let writer = try writerFactory(url, inputFormat)
    let state = CaptureState()
    installTap(on: engine, writer: writer, state: state)

    do {
      engine.prepare()
      let startedAt = now()
      try engine.start()
      self.engine = engine
      self.writer = writer
      self.state = state
      try await waitForFirstWrite(state)
      observeAudioSessionLifecycle()
      return startedAt
    } catch is CancellationError {
      try? stop()
      throw CancellationError()
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
      state.continuation.finish()
      self.engine = nil
      writer.cancel()
      self.writer = nil
      self.state = nil
      deactivateAudioSession()
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  func frames() -> AsyncStream<AudioFrame> {
    state?.stream ?? AsyncStream { $0.finish() }
  }

  func events() -> AsyncStream<RecordingCaptureEvent> {
    state?.eventStream ?? AsyncStream { $0.finish() }
  }

  func stop() throws {
    try lifecycleLock.withLock {
      removeAudioSessionLifecycleObservers()
      if let terminalStopError {
        throw terminalStopError
      }
      if let engine {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state?.continuation.finish()
        state?.eventContinuation.finish()
        self.engine = nil
        deactivateAudioSession()
      }
      guard let writer else {
        return
      }
      do {
        try writer.finish()
      } catch {
        throw RecordingError.recordingWriteFailed
      }
      self.writer = nil
      if state?.status().error != nil {
        terminalStopError = .recordingWriteFailed
        state = nil
        throw RecordingError.recordingWriteFailed
      }
      state = nil
    }
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

  private func installTap(
    on engine: AVAudioEngine,
    writer: any FragmentedAudioWriting,
    state: CaptureState
  ) {
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    input.installTap(
      onBus: 0,
      bufferSize: 2_048,
      format: inputFormat
    ) { buffer, _ in
      do {
        try writer.append(buffer)
        state.recordWriteSuccess()
      } catch {
        state.recordWriteFailure(error)
        return
      }

      let framePosition = state.takeFramePosition(
        advancingBy: buffer.frameLength
      )
      if let frame = Self.copyFrame(
        buffer,
        startFrame: framePosition
      ) {
        state.continuation.yield(frame)
      }
    }
  }

  #if os(iOS)
    private func observeAudioSessionLifecycle() {
      let center = NotificationCenter.default
      lifecycleObservers = [
        center.addObserver(
          forName: AVAudioSession.interruptionNotification,
          object: AVAudioSession.sharedInstance(),
          queue: nil
        ) { [weak self] notification in
          self?.handleInterruption(notification)
        },
        center.addObserver(
          forName: AVAudioSession.routeChangeNotification,
          object: AVAudioSession.sharedInstance(),
          queue: nil
        ) { [weak self] notification in
          self?.handleRouteChange(notification)
        },
        center.addObserver(
          forName: AVAudioSession.mediaServicesWereResetNotification,
          object: AVAudioSession.sharedInstance(),
          queue: nil
        ) { [weak self] _ in
          self?.recoverCapture(reason: .mediaServicesReset, rebuildEngine: true)
        },
      ]
    }

    private func removeAudioSessionLifecycleObservers() {
      let center = NotificationCenter.default
      lifecycleObservers.forEach(center.removeObserver)
      lifecycleObservers.removeAll()
    }

    private func handleInterruption(_ notification: Notification) {
      guard
        let rawType = notification.userInfo?[
          AVAudioSessionInterruptionTypeKey
        ] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: rawType)
      else {
        return
      }

      switch type {
      case .began:
        lifecycleLock.withLock {
          state?.eventContinuation.yield(
            .interruptionBegan(
              at: now(),
              reason: .systemInterruption
            )
          )
        }
      case .ended:
        let rawOptions =
          notification.userInfo?[AVAudioSessionInterruptionOptionKey]
          as? UInt ?? 0
        let mayResume = AVAudioSession.InterruptionOptions(
          rawValue: rawOptions
        ).contains(.shouldResume)
        guard mayResume else {
          lifecycleLock.withLock {
            state?.eventContinuation.yield(
              .interruptionEnded(at: now(), didResume: false)
            )
          }
          return
        }
        resumeCapture()
      @unknown default:
        break
      }
    }

    private func handleRouteChange(_ notification: Notification) {
      guard
        let rawReason = notification.userInfo?[
          AVAudioSessionRouteChangeReasonKey
        ] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
      else {
        return
      }

      switch reason {
      case .newDeviceAvailable, .oldDeviceUnavailable,
        .noSuitableRouteForCategory, .routeConfigurationChange:
        recoverCapture(reason: .routeChange, rebuildEngine: true)
      case .categoryChange, .override, .wakeFromSleep, .unknown:
        break
      @unknown default:
        break
      }
    }

    private func resumeCapture() {
      lifecycleLock.withLock {
        guard let engine, let state else {
          return
        }
        do {
          try configureAndActivateAudioSession()
          let attempt = state.writeMonitor.beginRecovery()
          if !engine.isRunning {
            engine.prepare()
            try engine.start()
          }
          guard engine.isRunning else {
            throw RecordingError.recordingWriteFailed
          }
          confirmRecoveryWrite(attempt, state: state)
        } catch {
          state.recordWriteFailure(error)
          state.eventContinuation.yield(
            .interruptionEnded(at: now(), didResume: false)
          )
        }
      }
    }

    private func recoverCapture(
      reason: RecordingInterruptionReason,
      rebuildEngine: Bool
    ) {
      lifecycleLock.withLock {
        guard let currentEngine = engine, let writer, let state else {
          return
        }
        state.eventContinuation.yield(
          .interruptionBegan(at: now(), reason: reason)
        )

        do {
          try configureAndActivateAudioSession()
          let attempt: AudioCaptureWriteMonitor.RecoveryAttempt
          if rebuildEngine {
            currentEngine.inputNode.removeTap(onBus: 0)
            currentEngine.stop()
            attempt = state.writeMonitor.beginRecovery()
            let replacement = AVAudioEngine()
            installTap(
              on: replacement,
              writer: writer,
              state: state
            )
            replacement.prepare()
            try replacement.start()
            engine = replacement
            guard replacement.isRunning else {
              throw RecordingError.recordingWriteFailed
            }
          } else {
            attempt = state.writeMonitor.beginRecovery()
            if !currentEngine.isRunning {
              currentEngine.prepare()
              try currentEngine.start()
            }
            guard currentEngine.isRunning else {
              throw RecordingError.recordingWriteFailed
            }
          }
          confirmRecoveryWrite(attempt, state: state)
        } catch {
          state.recordWriteFailure(error)
          state.eventContinuation.yield(
            .interruptionEnded(at: now(), didResume: false)
          )
        }
      }
    }

    private func confirmRecoveryWrite(
      _ attempt: AudioCaptureWriteMonitor.RecoveryAttempt,
      state: CaptureState
    ) {
      Task { [weak self] in
        guard let self else {
          return
        }
        let confirmation: AudioCaptureWriteMonitor.RecoveryConfirmation
        do {
          confirmation = try await state.writeMonitor.waitForRecoveryWrite(
            attempt,
            timeout: firstWriteTimeout,
            pollingInterval: pollingInterval
          )
        } catch {
          return
        }
        guard confirmation != .superseded else {
          return
        }
        if confirmation == .failed {
          state.recordWriteFailure(RecordingError.recordingWriteFailed)
        }
        lifecycleLock.withLock {
          guard self.state === state else {
            return
          }
          state.eventContinuation.yield(
            .interruptionEnded(
              at: now(),
              didResume: confirmation == .resumed
            )
          )
        }
      }
    }

    private func configureAndActivateAudioSession() throws {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .record,
        mode: .measurement,
        options: [.allowBluetoothHFP]
      )
      try session.setActive(true)
    }
  #else
    private func observeAudioSessionLifecycle() {}
    private func removeAudioSessionLifecycleObservers() {}
  #endif

  private func deactivateAudioSession() {
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    #endif
  }
}
