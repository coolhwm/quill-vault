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
  public private(set) var requiresMinutesReplacementConfirmation = false
  public private(set) var generationProfiles: [ModelProfile] = []
  public private(set) var selectedGenerationProfileID: ModelProfileID?
  public private(set) var selectedTranscriptVersion: TranscriptVersionKind = .original
  public private(set) var isComparingTranscripts = false
  public private(set) var transcriptOptimizeBusy = false
  public private(set) var transcriptOptimizeError = false
  public private(set) var selectedDetailTab: MeetingDetailTab = .smartMinutes
  public var draftTitle: String = ""
  public private(set) var titleSaveBusy = false
  public private(set) var titleSaveError = false
  public private(set) var displayedTitle: String = ""
  /// Default is read-only; edit mode is opt-in (#48).
  public private(set) var isEditingTitle = false

  public enum MeetingDetailTab: String, CaseIterable, Identifiable, Sendable {
    case smartMinutes
    case transcript

    public var id: String { rawValue }
  }

  private let directory: AuthoritativeDirectory
  /// Mutable so hand-edited titles stay available for regenerate before rescan.
  private var meeting: MeetingIndexEntry
  private let detail: any MeetingDetailUseCase
  private let player: any MeetingAudioPlayer
  private let generation: (any GenerationUseCase)?
  private let modelProfiles: (any ModelProfileUseCase)?
  private let transcriptQuality: (any TranscriptQualityUseCase)?
  private let titleAccess: (any MinutesTitleAccess)?
  private let cancelScheduledGeneration: (@Sendable (UUID) async -> Void)?
  private var progressTask: Task<Void, Never>?
  private var loadedAudioAsset: MeetingAudioAsset?

  public init(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    detail: any MeetingDetailUseCase,
    player: any MeetingAudioPlayer,
    generation: (any GenerationUseCase)? = nil,
    modelProfiles: (any ModelProfileUseCase)? = nil,
    transcriptQuality: (any TranscriptQualityUseCase)? = nil,
    titleAccess: (any MinutesTitleAccess)? = nil,
    cancelScheduledGeneration: (@Sendable (UUID) async -> Void)? = nil
  ) {
    self.directory = directory
    self.meeting = meeting
    self.detail = detail
    self.player = player
    self.generation = generation
    self.modelProfiles = modelProfiles
    self.transcriptQuality = transcriptQuality
    self.titleAccess = titleAccess
    self.cancelScheduledGeneration = cancelScheduledGeneration
  }

  public func selectDetailTab(_ tab: MeetingDetailTab) {
    selectedDetailTab = tab
  }

  public func beginTitleEditing() {
    draftTitle = displayedTitle
    titleSaveError = false
    isEditingTitle = true
  }

  public func cancelTitleEditing() {
    draftTitle = displayedTitle
    titleSaveError = false
    isEditingTitle = false
  }

  public func saveTitle() async {
    guard let titleAccess, !titleSaveBusy else {
      return
    }
    let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      titleSaveError = true
      return
    }
    titleSaveBusy = true
    titleSaveError = false
    defer { titleSaveBusy = false }
    do {
      try await titleAccess.updateTitle(
        title,
        userEdited: true,
        in: directory,
        meeting: meeting
      )
      // Keep local index entry and chrome in sync before catalog rescan.
      meeting = meeting.withTitle(title)
      displayedTitle = title
      draftTitle = title
      isEditingTitle = false
      state = .idle
      await load()
      // loadMeetingDetail prefers minutes.md title; still re-assert hand-edit.
      meeting = meeting.withTitle(title)
      displayedTitle = title
      draftTitle = title
      isEditingTitle = false
    } catch {
      titleSaveError = true
    }
  }

  public func retryPlayback() async {
    guard let loadedAudioAsset else {
      return
    }
    playbackFailed = false
    do {
      playback = try await player.load(loadedAudioAsset)
    } catch {
      playbackFailed = true
    }
  }

  public func selectTranscriptVersion(_ version: TranscriptVersionKind) {
    selectedTranscriptVersion = version
    if version != .optimized {
      isComparingTranscripts = false
    }
  }

  public func setTranscriptCompare(_ enabled: Bool) {
    guard case .loaded(let detail) = state, detail.hasOptimizedTranscript else {
      isComparingTranscripts = false
      return
    }
    isComparingTranscripts = enabled
  }

  public func optimizeTranscript() async {
    guard let transcriptQuality, !transcriptOptimizeBusy else {
      return
    }
    transcriptOptimizeBusy = true
    transcriptOptimizeError = false
    defer { transcriptOptimizeBusy = false }
    do {
      _ = try await transcriptQuality.optimizeAndPublish(
        in: directory,
        meeting: meeting
      )
      state = .idle
      await load()
      selectedTranscriptVersion = .optimized
    } catch {
      transcriptOptimizeError = true
    }
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
      // Prefer durable title from minutes (via detail load) over stale catalog entry.
      if let loadedTitle = loaded.meeting.title, !loadedTitle.isEmpty {
        meeting = meeting.withTitle(loadedTitle)
      }
      state = .loaded(
        MeetingDetail(
          meeting: meeting.withTitle(loaded.meeting.title ?? meeting.title),
          transcript: loaded.transcript,
          optimizedTranscript: loaded.optimizedTranscript,
          recording: loaded.recording,
          minutes: loaded.minutes
        )
      )
      displayedTitle = meeting.title ?? draftTitle
      if draftTitle.isEmpty || draftTitle == meeting.title {
        draftTitle = displayedTitle
      }
      if loaded.hasOptimizedTranscript {
        selectedTranscriptVersion = .optimized
      } else {
        selectedTranscriptVersion = .original
      }
      isComparingTranscripts = false
      await loadGeneration()
      await loadGenerationProfiles()
      if case .available(let asset) = loaded.recording {
        loadedAudioAsset = asset
        do {
          playback = try await player.load(asset)
          playbackFailed = false
        } catch is CancellationError {
          await player.unload()
          state = .idle
          return
        } catch {
          // Retry once after a short delay — common after cold security-scope attach.
          try? await Task.sleep(for: .milliseconds(200))
          do {
            playback = try await player.load(asset)
            playbackFailed = false
          } catch {
            playbackFailed = true
          }
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
    requiresMinutesReplacementConfirmation = false
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
      requiresMinutesReplacementConfirmation =
        snapshot.job.pauseReason == .externalMinutesChanged
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

  public func resumeGeneration(
    replacingExternalMinutes: Bool = false
  ) async {
    guard
      let generation,
      let snapshot = generationSnapshot,
      snapshot.job.state != .completed,
      !generationBusy
    else {
      return
    }
    if snapshot.job.pauseReason == .externalMinutesChanged,
      !replacingExternalMinutes
    {
      requiresMinutesReplacementConfirmation = true
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
        meeting: meeting,
        replacingExternalMinutes: replacingExternalMinutes
      )
      generationSnapshot = resumed
      requiresMinutesReplacementConfirmation =
        resumed.job.pauseReason == .externalMinutesChanged
      if resumed.job.state == .completed {
        state = .idle
        await load()
      }
    } catch {
      generationError = true
      await loadGeneration()
    }
  }

  public func regenerateGeneration(
    replacingExternalMinutes: Bool = false,
    optimizingTranscriptFirst: Bool = false
  ) async {
    guard let generation, !generationBusy else {
      return
    }
    if optimizingTranscriptFirst {
      await optimizeTranscript()
      if transcriptOptimizeError {
        return
      }
    }
    if let snapshot = generationSnapshot,
      snapshot.job.pauseReason == .externalMinutesChanged,
      !replacingExternalMinutes
    {
      requiresMinutesReplacementConfirmation = true
      return
    }
    generationBusy = true
    generationError = false
    if replacingExternalMinutes {
      requiresMinutesReplacementConfirmation = false
    }
    let poller = makeGenerationPoller(generation)
    defer {
      poller.cancel()
      generationBusy = false
    }
    do {
      let regenerated: GenerationSnapshot
      if replacingExternalMinutes,
        let snapshot = generationSnapshot,
        snapshot.job.state == .paused
      {
        regenerated = try await generation.resume(
          snapshot.job.id,
          in: directory,
          meeting: meeting,
          replacingExternalMinutes: true
        )
      } else {
        regenerated = try await generation.regenerate(
          in: directory,
          meeting: meeting,
          replacingExternalMinutes: replacingExternalMinutes
        )
      }
      generationSnapshot = regenerated
      requiresMinutesReplacementConfirmation =
        regenerated.job.pauseReason == .externalMinutesChanged
      if regenerated.job.state == .completed {
        state = .idle
        await load()
      }
    } catch GenerationWorkflowError.externalMinutesChanged {
      requiresMinutesReplacementConfirmation = true
    } catch {
      generationError = true
      await loadGeneration()
    }
  }

  public func selectGenerationProfile(_ id: ModelProfileID) async {
    guard let modelProfiles else {
      return
    }
    do {
      try await modelProfiles.select(id)
      await loadGenerationProfiles()
    } catch {
      generationError = true
    }
  }

  public func cancelGeneration() async {
    guard let generation, let snapshot = generationSnapshot else {
      return
    }
    await generation.cancel(snapshot.job.id)
    await cancelScheduledGeneration?(snapshot.job.id)
    requiresMinutesReplacementConfirmation = false
    await loadGeneration()
  }

  public func dismissMinutesReplacementConfirmation() {
    requiresMinutesReplacementConfirmation = false
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
      requiresMinutesReplacementConfirmation =
        generationSnapshot?.job.pauseReason == .externalMinutesChanged
    } catch {
      generationError = true
    }
  }

  private func loadGenerationProfiles() async {
    guard let modelProfiles else {
      generationProfiles = []
      selectedGenerationProfileID = nil
      return
    }
    do {
      let collection = try await modelProfiles.load()
      generationProfiles = collection.profiles.filter(\.isUsable)
      selectedGenerationProfileID = collection.currentProfileID
    } catch {
      generationProfiles = []
      selectedGenerationProfileID = nil
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
