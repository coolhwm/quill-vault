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
  public private(set) var generationSnapshot: GenerationSnapshot?
  public private(set) var generationBusy = false
  public private(set) var generationError = false

  private let directory: AuthoritativeDirectory
  private let meeting: MeetingIndexEntry
  private let detail: any MeetingDetailUseCase
  private let player: any MeetingAudioPlayer
  private let generation: (any GenerationUseCase)?
  private let cancelScheduledGeneration: (@Sendable (UUID) async -> Void)?
  private var progressTask: Task<Void, Never>?

  public init(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    detail: any MeetingDetailUseCase,
    player: any MeetingAudioPlayer,
    generation: (any GenerationUseCase)? = nil,
    cancelScheduledGeneration: (@Sendable (UUID) async -> Void)? = nil
  ) {
    self.directory = directory
    self.meeting = meeting
    self.detail = detail
    self.player = player
    self.generation = generation
    self.cancelScheduledGeneration = cancelScheduledGeneration
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
      await loadGeneration()
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

  public func startGeneration() async {
    guard let generation, !generationBusy else {
      return
    }
    generationBusy = true
    generationError = false
    let poller = makeGenerationPoller(generation)
    defer {
      poller.cancel()
      generationBusy = false
    }
    do {
      let snapshot = try await generation.start(
        in: directory,
        meeting: meeting
      )
      generationSnapshot = snapshot
      if snapshot.job.state == .completed {
        state = .idle
        await load()
      }
    } catch GenerationWorkflowError.activeJobExists {
      await loadGeneration()
      generationError = true
    } catch {
      generationError = true
      await loadGeneration()
    }
  }

  public func resumeGeneration() async {
    guard
      let generation,
      let snapshot = generationSnapshot,
      snapshot.job.state != .completed,
      !generationBusy
    else {
      return
    }
    generationBusy = true
    generationError = false
    let poller = makeGenerationPoller(generation)
    defer {
      poller.cancel()
      generationBusy = false
    }
    do {
      let resumed = try await generation.resume(
        snapshot.job.id,
        in: directory,
        meeting: meeting
      )
      generationSnapshot = resumed
      if resumed.job.state == .completed {
        state = .idle
        await load()
      }
    } catch {
      generationError = true
      await loadGeneration()
    }
  }

  public func cancelGeneration() async {
    guard let generation, let snapshot = generationSnapshot else {
      return
    }
    await generation.cancel(snapshot.job.id)
    await cancelScheduledGeneration?(snapshot.job.id)
    await loadGeneration()
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

  private func loadGeneration() async {
    guard let generation else {
      return
    }
    do {
      generationSnapshot = try await generation.load(meetingID: meeting.id)
    } catch {
      generationError = true
    }
  }

  private func makeGenerationPoller(
    _ generation: any GenerationUseCase
  ) -> Task<Void, Never> {
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard let self, !Task.isCancelled else {
          return
        }
        do {
          if let snapshot = try await generation.load(meetingID: meeting.id) {
            generationSnapshot = snapshot
          }
        } catch {
          return
        }
      }
    }
  }
}
