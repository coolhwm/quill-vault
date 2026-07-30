import AVFAudio
import CoreMedia
import Domain
import Foundation
import Speech

@available(iOS 26.0, macOS 26.0, *)
public struct SpeechAnalyzerTranscriptionEngine: SpeechTranscriptionEngine {
  private let dependencies: SpeechAnalyzerDependencies

  public init() {
    dependencies = .live
  }

  init(dependencies: SpeechAnalyzerDependencies) {
    self.dependencies = dependencies
  }

  public func liveResults(
    frames: AsyncStream<AudioFrame>,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    let prepared = try await prepare(localeIdentifier: localeIdentifier)
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [prepared.transcriber]
    )
    guard let analyzerFormat else {
      await releaseReservation(for: prepared)
      throw TranscriptError.speechAssetsUnavailable(localeIdentifier)
    }
    let analyzerInputs = AsyncStream<AnalyzerInput> { continuation in
      let task = Task {
        for await frame in frames {
          guard !Task.isCancelled else {
            break
          }
          do {
            guard let sourceBuffer = Self.makeBuffer(frame) else {
              continue
            }
            let buffer = try Self.convert(
              sourceBuffer,
              to: analyzerFormat
            )
            continuation.yield(
              AnalyzerInput(
                buffer: buffer,
                bufferStartTime: CMTime(
                  seconds: frame.startSeconds,
                  preferredTimescale: 1_000_000
                )
              )
            )
          } catch {
            continuation.finish()
            return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return makeStream(
      prepared: prepared,
      analysis: { analyzer in
        _ = try await analyzer.analyzeSequence(analyzerInputs)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      }
    )
  }

  public func fileResults(
    at recordingURL: URL,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream {
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: recordingURL)
    } catch {
      throw TranscriptError.recognitionFailed
    }
    let prepared = try await prepare(localeIdentifier: localeIdentifier)
    return makeStream(
      prepared: prepared,
      analysis: { analyzer in
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      }
    )
  }

  func prepare(
    localeIdentifier: String
  ) async throws -> PreparedAnalyzer {
    let requestedLocale = Locale(identifier: localeIdentifier)
    guard
      let supportedLocale = await dependencies.supportedLocale(requestedLocale)
    else {
      throw TranscriptError.unsupportedLocale(localeIdentifier)
    }

    let transcriber = SpeechTranscriber(
      locale: supportedLocale,
      preset: .timeIndexedProgressiveTranscription
    )
    let modules: [any SpeechModule] = [transcriber]
    let status = await dependencies.assetStatus(modules)
    switch status {
    case .unsupported:
      throw TranscriptError.unsupportedLocale(localeIdentifier)
    case .supported, .downloading:
      do {
        try await dependencies.installAssets(modules)
      } catch let error as TranscriptError {
        throw error
      } catch {
        throw TranscriptError.speechAssetsUnavailable(localeIdentifier)
      }
    case .installed:
      break
    @unknown default:
      throw TranscriptError.speechAssetsUnavailable(localeIdentifier)
    }

    let ownsReservation: Bool
    do {
      ownsReservation = try await dependencies.reserveLocale(supportedLocale)
    } catch let error as TranscriptError {
      throw error
    } catch {
      throw TranscriptError.speechAssetsUnavailable(localeIdentifier)
    }

    return PreparedAnalyzer(
      analyzer: SpeechAnalyzer(
        modules: modules,
        options: SpeechAnalyzer.Options(
          priority: .userInitiated,
          modelRetention: .whileInUse
        )
      ),
      transcriber: transcriber,
      reservedLocale: ownsReservation ? supportedLocale : nil
    )
  }

  private func makeStream(
    prepared: PreparedAnalyzer,
    analysis: @escaping @Sendable (SpeechAnalyzer) async throws -> Void
  ) -> SpeechRecognitionStream {
    AsyncThrowingStream { continuation in
      let resultTask = Task {
        do {
          for try await result in prepared.transcriber.results {
            try Task.checkCancellation()
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(result.range.end)
            guard start.isFinite, end.isFinite else {
              continue
            }
            continuation.yield(
              SpeechRecognitionEvent(
                segment: TranscriptSegmentCandidate(
                  startSeconds: start,
                  endSeconds: end,
                  text: String(result.text.characters)
                ),
                stability: result.isFinal ? .final : .volatile
              )
            )
          }
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: TranscriptError.recognitionFailed)
        }
      }

      let analysisTask = Task {
        do {
          try await analysis(prepared.analyzer)
          _ = await resultTask.result
          await releaseReservation(for: prepared)
          continuation.finish()
        } catch is CancellationError {
          await prepared.analyzer.cancelAndFinishNow()
          resultTask.cancel()
          await releaseReservation(for: prepared)
          continuation.finish(throwing: CancellationError())
        } catch {
          await prepared.analyzer.cancelAndFinishNow()
          resultTask.cancel()
          await releaseReservation(for: prepared)
          continuation.finish(throwing: TranscriptError.recognitionFailed)
        }
      }

      continuation.onTermination = { _ in
        analysisTask.cancel()
        resultTask.cancel()
      }
    }
  }

  private func releaseReservation(for prepared: PreparedAnalyzer) async {
    guard let locale = prepared.reservedLocale else {
      return
    }
    _ = await dependencies.releaseLocale(locale)
  }

  private static func makeBuffer(_ frame: AudioFrame) -> AVAudioPCMBuffer? {
    guard
      frame.sampleRate > 0,
      frame.channelCount > 0,
      frame.frameCount > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: frame.sampleRate,
        channels: AVAudioChannelCount(frame.channelCount),
        interleaved: true
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frame.frameCount)
      )
    else {
      return nil
    }
    buffer.frameLength = AVAudioFrameCount(frame.frameCount)
    let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
    guard let destination = audioBuffer.mData else {
      return nil
    }
    let byteCount = min(Int(audioBuffer.mDataByteSize), frame.samples.count)
    frame.samples.copyBytes(
      to: destination.assumingMemoryBound(to: UInt8.self),
      count: byteCount
    )
    return buffer
  }

  private static func convert(
    _ source: AVAudioPCMBuffer,
    to targetFormat: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    if source.format == targetFormat {
      return source
    }
    guard
      let converter = AVAudioConverter(
        from: source.format,
        to: targetFormat
      )
    else {
      throw TranscriptError.recognitionFailed
    }
    let ratio = targetFormat.sampleRate / source.format.sampleRate
    let capacity = max(
      1,
      AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 1
    )
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: capacity
      )
    else {
      throw TranscriptError.recognitionFailed
    }

    let inputProvider = ConversionInputProvider(buffer: source)
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      inputProvider.next(status: inputStatus)
    }
    if conversionError != nil || status == .error {
      throw TranscriptError.recognitionFailed
    }
    return output
  }
}

private final class ConversionInputProvider: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var didSupply = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(
    status: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    lock.withLock {
      guard !didSupply else {
        status.pointee = .noDataNow
        return nil
      }
      didSupply = true
      status.pointee = .haveData
      return buffer
    }
  }
}

@available(iOS 26.0, macOS 26.0, *)
struct PreparedAnalyzer: @unchecked Sendable {
  let analyzer: SpeechAnalyzer
  let transcriber: SpeechTranscriber
  let reservedLocale: Locale?
}

@available(iOS 26.0, macOS 26.0, *)
struct SpeechAnalyzerDependencies: Sendable {
  let supportedLocale: @Sendable (Locale) async -> Locale?
  let assetStatus: @Sendable ([any SpeechModule]) async -> AssetInventory.Status
  let installAssets: @Sendable ([any SpeechModule]) async throws -> Void
  let reserveLocale: @Sendable (Locale) async throws -> Bool
  let releaseLocale: @Sendable (Locale) async -> Bool

  static let live = Self(
    supportedLocale: {
      await SpeechTranscriber.supportedLocale(equivalentTo: $0)
    },
    assetStatus: {
      await AssetInventory.status(forModules: $0)
    },
    installAssets: { modules in
      if let request = try await AssetInventory.assetInstallationRequest(
        supporting: modules
      ) {
        try await request.downloadAndInstall()
      }
    },
    reserveLocale: {
      try await AssetInventory.reserve(locale: $0)
    },
    releaseLocale: {
      await AssetInventory.release(reservedLocale: $0)
    }
  )
}
