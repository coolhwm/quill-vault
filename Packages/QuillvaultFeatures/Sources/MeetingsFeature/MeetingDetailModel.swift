import Application
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingDetailModel {
  public enum State: Equatable {
    case idle
    case loading
    case loaded(MeetingDetail)
    case failed
  }

  public private(set) var state: State = .idle
  public private(set) var playback = MeetingAudioPlaybackSnapshot(
    durationSeconds: 0,
    currentSeconds: 0,
    isPlaying: false
  )
  public private(set) var playbackFailed = false

  private let directory: AuthoritativeDirectory
  private let meeting: MeetingIndexEntry
  private let detail: any MeetingDetailUseCase
  private let player: any MeetingAudioPlayer
  private var progressTask: Task<Void, Never>?

  public init(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    detail: any MeetingDetailUseCase,
    player: any MeetingAudioPlayer
  ) {
    self.directory = directory
    self.meeting = meeting
    self.detail = detail
    self.player = player
  }

  public func load() async {
    guard state == .idle || state == .failed else {
      return
    }
    state = .loading
    do {
      let loaded = try await detail.load(
        directory: directory,
        meeting: meeting
      )
      state = .loaded(loaded)
      if case .available(let asset) = loaded.recording {
        do {
          playback = try await player.load(asset)
        } catch is CancellationError {
          await player.unload()
          state = .idle
          return
        } catch {
          playbackFailed = true
        }
      }
    } catch is CancellationError {
      await player.unload()
      state = .idle
    } catch {
      state = .failed
    }
  }

  public func togglePlayback() {
    do {
      playback = playback.isPlaying ? player.pause() : try player.play()
      playbackFailed = false
      updateProgressWhilePlaying()
    } catch {
      playbackFailed = true
    }
  }

  public func seek(to seconds: Double, beginsPlayback: Bool) {
    do {
      playback = try player.seek(to: seconds)
      if beginsPlayback {
        playback = try player.play()
      }
      playbackFailed = false
      updateProgressWhilePlaying()
    } catch {
      playbackFailed = true
    }
  }

  public func unload() {
    progressTask?.cancel()
    Task {
      await player.unload()
    }
  }

  private func updateProgressWhilePlaying() {
    progressTask?.cancel()
    guard playback.isPlaying else {
      return
    }
    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        guard let self else {
          return
        }
        playback = player.snapshot()
        if !playback.isPlaying {
          return
        }
      }
    }
  }
}
