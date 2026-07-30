import AVFAudio
import AudioToolbox
import Domain
import Foundation

struct AVRecordedAudioValidator: RecordedAudioValidating {
  private let containerInspector = M4AContainerInspector()

  func validate(_ url: URL) throws -> RecordedAudio {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: url)
    } catch {
      throw validationError(from: error, at: url)
    }
    let sampleRate = audioFile.processingFormat.sampleRate
    let frameCount = audioFile.length
    let packetCount = try readPacketCount(url)
    let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0

    let audio = RecordedAudio(
      durationSeconds: duration,
      packetCount: packetCount,
      byteCount: byteCount,
      fileURL: url
    )
    guard audio.isValid else {
      throw RecordingError.invalidRecordedAudio
    }
    return audio
  }

  private func readPacketCount(_ url: URL) throws -> Int64 {
    var file: AudioFileID?
    let openStatus = AudioFileOpenURL(
      url as CFURL,
      .readPermission,
      0,
      &file
    )
    guard openStatus == noErr, let file else {
      throw validationError(from: openStatus, at: url)
    }
    defer {
      AudioFileClose(file)
    }

    var packetCount: UInt64 = 0
    var propertySize = UInt32(MemoryLayout<UInt64>.size)
    let propertyStatus = AudioFileGetProperty(
      file,
      kAudioFilePropertyAudioDataPacketCount,
      &propertySize,
      &packetCount
    )
    guard propertyStatus == noErr else {
      throw validationError(from: propertyStatus, at: url)
    }
    return Int64(clamping: packetCount)
  }

  static func isDefinitiveContentFailure(_ status: OSStatus) -> Bool {
    switch status {
    case kAudioFileUnsupportedFileTypeError,
      kAudioFileUnsupportedDataFormatError,
      kAudioFileInvalidChunkError,
      kAudioFileInvalidPacketOffsetError,
      kAudioFileInvalidPacketDependencyError,
      kAudioFileInvalidFileError,
      kExtAudioFileError_InvalidDataFormat:
      return true
    default:
      return false
    }
  }

  private func validationError(
    from error: Error,
    at url: URL
  ) -> any Error {
    validationError(
      from: OSStatus(truncatingIfNeeded: (error as NSError).code),
      at: url,
      fallback: error
    )
  }

  private func validationError(
    from status: OSStatus,
    at url: URL,
    fallback: (any Error)? = nil
  ) -> any Error {
    if Self.isDefinitiveContentFailure(status) {
      return RecordingError.invalidRecordedAudio
    }
    if status == kAudioFileUnspecifiedError,
      containerInspector.isStructurallyInvalid(url) == true
    {
      return RecordingError.invalidRecordedAudio
    }
    return fallback
      ?? NSError(domain: NSOSStatusErrorDomain, code: Int(status))
  }
}
