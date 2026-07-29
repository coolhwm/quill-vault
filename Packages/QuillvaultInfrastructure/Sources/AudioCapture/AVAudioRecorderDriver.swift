import AVFAudio
import AudioToolbox
import Domain
import Foundation

protocol SystemAudioRecording: AnyObject {
  var currentTime: TimeInterval { get }
  func prepareToRecord() -> Bool
  func record() -> Bool
  func stop()
}

extension AVAudioRecorder: SystemAudioRecording {}

final class AVAudioRecorderDriver: AudioRecorderDriving, @unchecked Sendable {
  typealias RecorderFactory = @Sendable (URL) throws -> any SystemAudioRecording
  typealias ByteCountReader = @Sendable (URL) -> Int64

  private let makeRecorder: RecorderFactory
  private let byteCount: ByteCountReader
  private let firstWriteTimeout: Duration
  private let pollingInterval: Duration
  private var recorder: (any SystemAudioRecording)?

  init() {
    makeRecorder = { url in
      try AVAudioRecorder(
        url: url,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 44_100,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 64_000,
          AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
      )
    }
    byteCount = Self.fileByteCount
    firstWriteTimeout = .milliseconds(800)
    pollingInterval = .milliseconds(10)
  }

  init(
    makeRecorder: @escaping RecorderFactory,
    byteCount: @escaping ByteCountReader,
    firstWriteTimeout: Duration,
    pollingInterval: Duration = .milliseconds(1)
  ) {
    self.makeRecorder = makeRecorder
    self.byteCount = byteCount
    self.firstWriteTimeout = firstWriteTimeout
    self.pollingInterval = pollingInterval
  }

  func start(at url: URL) async throws -> Date {
    guard recorder == nil else {
      throw RecordingError.alreadyRecording
    }
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw RecordingError.captureCouldNotStart
    }

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .record,
        mode: .default,
        options: [.allowBluetoothHFP]
      )
      try session.setActive(true)
    #endif

    let recorder = try makeRecorder(url)
    guard recorder.prepareToRecord() else {
      deactivateAudioSession()
      throw RecordingError.captureCouldNotStart
    }
    let preparedByteCount = byteCount(url)
    let startedAt = Date()
    guard recorder.record() else {
      deactivateAudioSession()
      throw RecordingError.captureCouldNotStart
    }
    self.recorder = recorder

    do {
      try await waitForFirstPersistedAudio(
        at: url,
        preparedByteCount: preparedByteCount,
        recorder: recorder
      )
      return startedAt
    } catch is CancellationError {
      stop()
      throw CancellationError()
    } catch {
      stop()
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  func stop() {
    recorder?.stop()
    recorder = nil
    deactivateAudioSession()
  }

  private func waitForFirstPersistedAudio(
    at url: URL,
    preparedByteCount: Int64,
    recorder: any SystemAudioRecording
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: firstWriteTimeout)

    while clock.now < deadline {
      try Task.checkCancellation()
      if recorder.currentTime > 0,
        byteCount(url) > preparedByteCount
      {
        return
      }
      try await Task.sleep(for: pollingInterval)
    }
    throw RecordingError.recordingWriteFailed
  }

  private static func fileByteCount(at url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(
      atPath: url.path
    )
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
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
