@preconcurrency import AVFoundation
import CoreMedia
import Foundation

protocol FragmentedAudioWriting: AnyObject, Sendable {
  func append(_ sourceBuffer: AVAudioPCMBuffer) throws
  func finish() throws
  func cancel()
}

final class FragmentedM4AWriter: FragmentedAudioWriting, @unchecked Sendable {
  private final class ConversionInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
      self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
      defer {
        buffer = nil
      }
      return buffer
    }
  }

  private enum WriterFailure: Error {
    case cannotCreateFormat
    case cannotStart
    case conversionFailed
    case encoderBackpressure
    case appendFailed
    case finishTimedOut
  }

  private let lock = NSLock()
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let recordingFormat: AVAudioFormat
  private let formatDescription: CMAudioFormatDescription
  private let finishGroup = DispatchGroup()
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?
  private var framePosition: AVAudioFramePosition = 0
  private var isFinishing = false

  init(outputURL: URL, sourceFormat: AVAudioFormat) throws {
    finishGroup.enter()
    recordingFormat = AVAudioFormat(
      commonFormat: sourceFormat.commonFormat,
      sampleRate: sourceFormat.sampleRate,
      channels: sourceFormat.channelCount,
      interleaved: sourceFormat.isInterleaved
    )!

    var streamDescription = recordingFormat.streamDescription.pointee
    var createdDescription: CMAudioFormatDescription?
    let descriptionStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &streamDescription,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &createdDescription
    )
    guard descriptionStatus == noErr, let createdDescription else {
      throw WriterFailure.cannotCreateFormat
    }
    formatDescription = createdDescription

    writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    writer.movieFragmentInterval = CMTime(
      seconds: 0.5,
      preferredTimescale: 600
    )
    writer.initialMovieFragmentInterval = CMTime(
      seconds: 0.5,
      preferredTimescale: 600
    )
    input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: recordingFormat.sampleRate,
        AVNumberOfChannelsKey: recordingFormat.channelCount,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ],
      sourceFormatHint: createdDescription
    )
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
      throw WriterFailure.cannotStart
    }
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? WriterFailure.cannotStart
    }
    writer.startSession(atSourceTime: .zero)
  }

  func append(_ sourceBuffer: AVAudioPCMBuffer) throws {
    try lock.withLock {
      guard !isFinishing, writer.status == .writing else {
        throw writer.error ?? WriterFailure.appendFailed
      }
      let buffer = try convertedBuffer(sourceBuffer)
      let sampleBuffer = try makeSampleBuffer(buffer)
      try waitUntilReady()
      guard input.append(sampleBuffer) else {
        throw writer.error ?? WriterFailure.appendFailed
      }
      framePosition += AVAudioFramePosition(buffer.frameLength)
    }
  }

  func finish() throws {
    let endTime: CMTime? = lock.withLock {
      guard !isFinishing else {
        return nil
      }
      isFinishing = true
      return CMTime(
        value: framePosition,
        timescale: timeScale
      )
    }
    if let endTime {
      input.markAsFinished()
      writer.endSession(atSourceTime: endTime)
      writer.finishWriting { [finishGroup] in
        finishGroup.leave()
      }
    }
    guard finishGroup.wait(timeout: .now() + 10) == .success else {
      throw WriterFailure.finishTimedOut
    }
    guard writer.status == .completed else {
      throw writer.error ?? WriterFailure.appendFailed
    }
  }

  func cancel() {
    let shouldCancel = lock.withLock {
      guard !isFinishing else {
        return false
      }
      isFinishing = true
      return true
    }
    if shouldCancel {
      writer.cancelWriting()
      finishGroup.leave()
    }
  }

  private var timeScale: CMTimeScale {
    CMTimeScale(recordingFormat.sampleRate.rounded())
  }

  private func convertedBuffer(
    _ sourceBuffer: AVAudioPCMBuffer
  ) throws -> AVAudioPCMBuffer {
    if sourceBuffer.format == recordingFormat {
      return sourceBuffer
    }

    if converter == nil || converterInputFormat != sourceBuffer.format {
      converter = AVAudioConverter(
        from: sourceBuffer.format,
        to: recordingFormat
      )
      converterInputFormat = sourceBuffer.format
    }
    guard let converter else {
      throw WriterFailure.conversionFailed
    }
    let frameRatio =
      recordingFormat.sampleRate / sourceBuffer.format.sampleRate
    let capacity = AVAudioFrameCount(
      ceil(Double(sourceBuffer.frameLength) * frameRatio) + 32
    )
    guard
      let converted = AVAudioPCMBuffer(
        pcmFormat: recordingFormat,
        frameCapacity: capacity
      )
    else {
      throw WriterFailure.conversionFailed
    }

    let conversionInput = ConversionInput(sourceBuffer)
    var conversionError: NSError?
    let status = converter.convert(
      to: converted,
      error: &conversionError
    ) { _, outputStatus in
      guard let buffer = conversionInput.take() else {
        outputStatus.pointee = .noDataNow
        return nil
      }
      outputStatus.pointee = .haveData
      return buffer
    }
    guard
      conversionError == nil,
      status != .error,
      converted.frameLength > 0
    else {
      throw conversionError ?? WriterFailure.conversionFailed
    }
    return converted
  }

  private func makeSampleBuffer(
    _ buffer: AVAudioPCMBuffer
  ) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: timeScale),
      presentationTimeStamp: CMTime(
        value: framePosition,
        timescale: timeScale
      ),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let createStatus: OSStatus
    if recordingFormat.isInterleaved {
      var sampleSize = Int(recordingFormat.streamDescription.pointee.mBytesPerFrame)
      createStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: CMItemCount(buffer.frameLength),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      )
    } else {
      createStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: false,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: CMItemCount(buffer.frameLength),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
      )
    }
    guard createStatus == noErr, let sampleBuffer else {
      throw WriterFailure.appendFailed
    }
    let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sampleBuffer,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      bufferList: buffer.audioBufferList
    )
    guard dataStatus == noErr else {
      throw WriterFailure.appendFailed
    }
    let readyStatus = CMSampleBufferSetDataReady(sampleBuffer)
    guard readyStatus == noErr else {
      throw WriterFailure.appendFailed
    }
    return sampleBuffer
  }

  private func waitUntilReady() throws {
    guard writer.status == .writing else {
      throw writer.error ?? WriterFailure.appendFailed
    }
    guard input.isReadyForMoreMediaData else {
      throw WriterFailure.encoderBackpressure
    }
  }
}
