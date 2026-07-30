import AVFAudio
import Domain
import Foundation

public protocol MeetingAudioFileAccess: Sendable {
  func beginAudioPlayback(
    sourceID: MeetingAudioSourceID
  ) async throws -> URL
  func endAudioPlayback(sourceID: MeetingAudioSourceID) async
}

@MainActor
public final class SystemMeetingAudioPlayer: MeetingAudioPlayer {
  private let access: any MeetingAudioFileAccess
  private var player: AVAudioPlayer?
  private var activeSourceID: MeetingAudioSourceID?

  public init(access: any MeetingAudioFileAccess) {
    self.access = access
  }

  deinit {
    guard let activeSourceID else {
      return
    }
    let access = access
    Task {
      await access.endAudioPlayback(sourceID: activeSourceID)
    }
  }

  public func load(
    _ asset: MeetingAudioAsset
  ) async throws -> MeetingAudioPlaybackSnapshot {
    await unload()
    let url: URL
    do {
      url = try await access.beginAudioPlayback(sourceID: asset.sourceID)
    } catch {
      throw MeetingAudioPlaybackError.unavailable
    }
    activeSourceID = asset.sourceID
    do {
      let player = try coordinatedPlayer(at: url)
      guard player.prepareToPlay(), player.duration > 0 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      self.player = player
      return snapshot()
    } catch {
      await releaseAccess()
      throw MeetingAudioPlaybackError.unreadable
    }
  }

  public func play() throws -> MeetingAudioPlaybackSnapshot {
    guard let player else {
      throw MeetingAudioPlaybackError.unavailable
    }
    guard player.play() else {
      throw MeetingAudioPlaybackError.playbackFailed
    }
    return snapshot()
  }

  public func pause() -> MeetingAudioPlaybackSnapshot {
    player?.pause()
    return snapshot()
  }

  public func seek(to seconds: Double) throws -> MeetingAudioPlaybackSnapshot {
    guard let player else {
      throw MeetingAudioPlaybackError.unavailable
    }
    player.currentTime = min(max(0, seconds), player.duration)
    return snapshot()
  }

  public func snapshot() -> MeetingAudioPlaybackSnapshot {
    guard let player else {
      return MeetingAudioPlaybackSnapshot(
        durationSeconds: 0,
        currentSeconds: 0,
        isPlaying: false
      )
    }
    return MeetingAudioPlaybackSnapshot(
      durationSeconds: player.duration,
      currentSeconds: player.currentTime,
      isPlaying: player.isPlaying
    )
  }

  public func unload() async {
    player?.stop()
    player = nil
    await releaseAccess()
  }

  private func releaseAccess() async {
    guard let activeSourceID else {
      return
    }
    self.activeSourceID = nil
    await access.endAudioPlayback(sourceID: activeSourceID)
  }

  private func coordinatedPlayer(at url: URL) throws -> AVAudioPlayer {
    var coordinationError: NSError?
    var result: Result<AVAudioPlayer, Error>?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedURL in
      result = Result {
        try AVAudioPlayer(contentsOf: coordinatedURL)
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    guard let result else {
      throw CocoaError(.fileReadUnknown)
    }
    return try result.get()
  }
}
