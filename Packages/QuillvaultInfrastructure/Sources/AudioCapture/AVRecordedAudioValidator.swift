import AVFAudio
import AudioToolbox
import Domain
import Foundation

struct AVRecordedAudioValidator: RecordedAudioValidating {
  func validate(_ url: URL) throws -> RecordedAudio {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let audioFile = try AVAudioFile(forReading: url)
    let sampleRate = audioFile.processingFormat.sampleRate
    let frameCount = audioFile.length
    let packetCount = try readPacketCount(url)
    let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0

    let audio = RecordedAudio(
      durationSeconds: duration,
      packetCount: packetCount,
      byteCount: byteCount
    )
    guard audio.isValid else {
      throw RecordingError.invalidRecordedAudio
    }
    return audio
  }

  private func readPacketCount(_ url: URL) throws -> Int64 {
    var file: AudioFileID?
    guard
      AudioFileOpenURL(
        url as CFURL,
        .readPermission,
        0,
        &file
      ) == noErr,
      let file
    else {
      throw RecordingError.invalidRecordedAudio
    }
    defer {
      AudioFileClose(file)
    }

    var packetCount: UInt64 = 0
    var propertySize = UInt32(MemoryLayout<UInt64>.size)
    guard
      AudioFileGetProperty(
        file,
        kAudioFilePropertyAudioDataPacketCount,
        &propertySize,
        &packetCount
      ) == noErr
    else {
      throw RecordingError.invalidRecordedAudio
    }
    return Int64(clamping: packetCount)
  }
}
