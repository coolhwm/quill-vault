import AVFAudio
import Foundation
import Testing

@testable import AudioCapture

@Suite("Fragmented M4A writer")
struct FragmentedM4AWriterTests {
  @Test("Committed fragments remain playable before graceful finish")
  func remainsPlayableWhileOpen() throws {
    let directory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let recordingURL = directory.appendingPathComponent("recording.m4a")
    let format = AVAudioFormat(
      standardFormatWithSampleRate: 48_000,
      channels: 1
    )!
    let writer = try FragmentedM4AWriter(
      outputURL: recordingURL,
      sourceFormat: format
    )
    defer {
      writer.cancel()
    }
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: 4_800
    )!
    buffer.frameLength = 4_800

    for _ in 0..<20 {
      try writer.append(buffer)
    }

    let validator = AVRecordedAudioValidator()
    var recovered = try? validator.validate(recordingURL)
    let deadline = Date().addingTimeInterval(1)
    while recovered == nil, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
      recovered = try? validator.validate(recordingURL)
    }

    #expect(recovered?.isValid == true)
    #expect((recovered?.durationSeconds ?? 0) > 1)
  }

  @Test("Graceful finish preserves the complete recording")
  func gracefulFinishPreservesCompleteRecording() throws {
    let directory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let recordingURL = directory.appendingPathComponent("recording.m4a")
    let format = AVAudioFormat(
      standardFormatWithSampleRate: 48_000,
      channels: 1
    )!
    let writer = try FragmentedM4AWriter(
      outputURL: recordingURL,
      sourceFormat: format
    )
    let buffer = makeBuffer(format: format, frameCount: 4_800)

    for _ in 0..<20 {
      try writer.append(buffer)
    }
    try writer.finish()
    try writer.finish()

    let recovered = try AVRecordedAudioValidator().validate(recordingURL)
    #expect(recovered.isValid)
    #expect(recovered.durationSeconds > 1.9)
  }

  @Test("A route format change remains appendable and playable")
  func convertsBuffersAfterRouteFormatChange() throws {
    let directory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let recordingURL = directory.appendingPathComponent("recording.m4a")
    let recordingFormat = AVAudioFormat(
      standardFormatWithSampleRate: 48_000,
      channels: 1
    )!
    let changedRouteFormat = AVAudioFormat(
      standardFormatWithSampleRate: 44_100,
      channels: 1
    )!
    let writer = try FragmentedM4AWriter(
      outputURL: recordingURL,
      sourceFormat: recordingFormat
    )

    for _ in 0..<10 {
      try writer.append(
        makeBuffer(format: recordingFormat, frameCount: 4_800)
      )
    }
    for _ in 0..<10 {
      try writer.append(
        makeBuffer(format: changedRouteFormat, frameCount: 4_410)
      )
    }
    try writer.finish()

    let recovered = try AVRecordedAudioValidator().validate(recordingURL)
    #expect(recovered.isValid)
    #expect(recovered.durationSeconds > 1.9)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makeBuffer(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount
  ) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: frameCount
    )!
    buffer.frameLength = frameCount
    return buffer
  }
}
