import AVFAudio
import Domain
import Foundation
import Testing

@testable import AudioPlayback

@MainActor
@Suite("System meeting audio player")
struct SystemMeetingAudioPlayerTests {
  @Test("Loads, seeks, plays, pauses, and unloads a local recording")
  func playbackLifecycle() async throws {
    let audioURL = try makeSilentAudio()
    defer {
      try? FileManager.default.removeItem(
        at: audioURL.deletingLastPathComponent()
      )
    }
    let sourceID = MeetingAudioSourceID(rawValue: "test-audio")
    let access = AudioFileAccessStub(url: audioURL)
    let player = SystemMeetingAudioPlayer(access: access)
    let loaded = try await player.load(
      MeetingAudioAsset(
        sourceID: sourceID,
        durationSeconds: 1
      )
    )
    #expect(loaded.durationSeconds > 0.9)
    #expect(loaded.isPlaying == false)

    let clock = ContinuousClock()
    let startedAt = clock.now
    let sought = try player.seek(to: 0.5)
    #expect(sought.currentSeconds >= 0.49)
    #expect(try player.play().isPlaying)
    #expect(startedAt.duration(to: clock.now) < .milliseconds(300))
    #expect(player.pause().isPlaying == false)

    await player.unload()
    #expect(player.snapshot().durationSeconds == 0)
    #expect(await access.endedSourceIDs == [sourceID])
  }

  @Test("Maps file and AVFoundation failures to stable domain errors")
  func mapsAdapterErrors() async throws {
    let missingAccess = AudioFileAccessStub(
      result: .failure(CocoaError(.fileNoSuchFile))
    )
    let missingPlayer = SystemMeetingAudioPlayer(access: missingAccess)
    await #expect(throws: MeetingAudioPlaybackError.unavailable) {
      _ = try await missingPlayer.load(
        MeetingAudioAsset(
          sourceID: MeetingAudioSourceID(rawValue: "missing"),
          durationSeconds: 1
        )
      )
    }

    let invalidURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString
    )
    try Data([0]).write(to: invalidURL)
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    let unreadablePlayer = SystemMeetingAudioPlayer(
      access: AudioFileAccessStub(url: invalidURL)
    )
    await #expect(throws: MeetingAudioPlaybackError.unreadable) {
      _ = try await unreadablePlayer.load(
        MeetingAudioAsset(
          sourceID: MeetingAudioSourceID(rawValue: "unreadable"),
          durationSeconds: 1
        )
      )
    }

    #expect(throws: MeetingAudioPlaybackError.unavailable) {
      _ = try missingPlayer.play()
    }
    #expect(throws: MeetingAudioPlaybackError.unavailable) {
      _ = try missingPlayer.seek(to: 1)
    }
  }

  private func makeSilentAudio() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory.appending(path: "recording.caf")
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 44_100,
      channels: 1,
      interleaved: false
    )!
    let file = try AVAudioFile(
      forWriting: url,
      settings: format.settings
    )
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: 44_100
    )!
    buffer.frameLength = 44_100
    try file.write(from: buffer)
    return url
  }
}

private actor AudioFileAccessStub: MeetingAudioFileAccess {
  let result: Result<URL, Error>
  private(set) var endedSourceIDs: [MeetingAudioSourceID] = []

  init(url: URL) {
    result = .success(url)
  }

  init(result: Result<URL, Error>) {
    self.result = result
  }

  func beginAudioPlayback(
    sourceID: MeetingAudioSourceID
  ) async throws -> URL {
    try result.get()
  }

  func endAudioPlayback(sourceID: MeetingAudioSourceID) async {
    endedSourceIDs.append(sourceID)
  }
}
