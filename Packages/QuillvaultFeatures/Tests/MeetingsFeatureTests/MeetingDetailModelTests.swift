import Application
import Domain
import Foundation
import Testing

@testable import MeetingsFeature

@MainActor
@Suite("Meeting detail model")
struct MeetingDetailModelTests {
  @Test("Loads transcript and recording when minutes are missing")
  func loadsIndependentAssets() async {
    let detail = MeetingDetail.fixture
    let player = MeetingAudioPlayerSpy()
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: MeetingDetailUseCaseStub(detail: detail),
      player: player
    )

    await model.load()

    #expect(model.state == .loaded(detail))
    #expect(player.loadedAssets.count == 1)
    #expect(model.playback.durationSeconds == 20)
  }

  @Test("Selecting a timestamp seeks and starts playback")
  func transcriptSelectionStartsPlayback() async {
    let player = MeetingAudioPlayerSpy()
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: MeetingDetailUseCaseStub(detail: .fixture),
      player: player
    )
    await model.load()

    model.seek(to: 12.5, beginsPlayback: true)

    #expect(player.seekPositions == [12.5])
    #expect(player.playCount == 1)
    #expect(model.playback.currentSeconds == 12.5)
    #expect(model.playback.isPlaying)
  }

  @Test("Cancellation returns to idle without projecting a failure")
  func cancellationIsNotFailure() async {
    let player = MeetingAudioPlayerSpy()
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: CancellingMeetingDetailUseCase(),
      player: player
    )

    await model.load()

    #expect(model.state == .idle)
    #expect(player.unloadCount == 1)
  }

  @Test("Detail tab defaults to smart minutes and can switch")
  func selectsDetailTabs() async {
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: MeetingDetailUseCaseStub(detail: .fixture),
      player: MeetingAudioPlayerSpy()
    )
    await model.load()
    #expect(model.selectedDetailTab == .smartMinutes)
    model.selectDetailTab(.transcript)
    #expect(model.selectedDetailTab == .transcript)
    model.selectDetailTab(.smartMinutes)
    #expect(model.selectedDetailTab == .smartMinutes)
  }

  @Test("Title editing is opt-in and cancel restores draft")
  func titleEditingIsOptIn() async {
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: MeetingDetailUseCaseStub(detail: .fixture),
      player: MeetingAudioPlayerSpy()
    )
    await model.load()
    #expect(model.isEditingTitle == false)
    model.beginTitleEditing()
    #expect(model.isEditingTitle == true)
    model.draftTitle = "temporary"
    model.cancelTitleEditing()
    #expect(model.isEditingTitle == false)
    #expect(model.draftTitle == model.displayedTitle)
  }

  @Test("Loads optimized transcript version when available")
  func selectsOptimizedWhenPresent() async {
    let player = MeetingAudioPlayerSpy()
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: MeetingDetailUseCaseStub(detail: .fixtureWithOptimized),
      player: player
    )

    await model.load()

    #expect(model.selectedTranscriptVersion == .optimized)
    model.selectTranscriptVersion(.original)
    #expect(model.selectedTranscriptVersion == .original)
    #expect(model.isComparingTranscripts == false)
    model.setTranscriptCompare(true)
    #expect(model.isComparingTranscripts)
    model.selectTranscriptVersion(.optimized)
    #expect(model.selectedTranscriptVersion == .optimized)
  }

  @Test("optimizeTranscript publishes and reloads optimized version")
  func optimizePublishesAndSelectsOptimized() async {
    let quality = TranscriptQualityUseCaseSpy()
    let detail = ReloadableMeetingDetailUseCase(
      first: .fixture,
      second: .fixtureWithOptimized
    )
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: detail,
      player: MeetingAudioPlayerSpy(),
      transcriptQuality: quality
    )

    await model.load()
    #expect(model.selectedTranscriptVersion == .original)

    await model.optimizeTranscript()

    #expect(await quality.publishCount == 1)
    #expect(model.transcriptOptimizeError == false)
    #expect(model.selectedTranscriptVersion == .optimized)
    #expect(model.state == .loaded(.fixtureWithOptimized))
  }

  @Test("optimizeTranscript failure keeps original selection")
  func optimizeFailureSurfacesError() async {
    let quality = TranscriptQualityUseCaseSpy(shouldFail: true)
    let model = MeetingDetailModel(
      directory: .fixture,
      meeting: .fixture,
      detail: MeetingDetailUseCaseStub(detail: .fixture),
      player: MeetingAudioPlayerSpy(),
      transcriptQuality: quality
    )

    await model.load()
    await model.optimizeTranscript()

    #expect(model.transcriptOptimizeError)
    #expect(model.selectedTranscriptVersion == .original)
  }
}

private struct MeetingDetailUseCaseStub: MeetingDetailUseCase {
  let detail: MeetingDetail

  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    detail
  }
}

private struct CancellingMeetingDetailUseCase: MeetingDetailUseCase {
  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    throw CancellationError()
  }
}

private final class ReloadableMeetingDetailUseCase: MeetingDetailUseCase, @unchecked Sendable {
  private let first: MeetingDetail
  private let second: MeetingDetail
  private var loadCount = 0

  init(first: MeetingDetail, second: MeetingDetail) {
    self.first = first
    self.second = second
  }

  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    loadCount += 1
    return loadCount == 1 ? first : second
  }
}

private actor TranscriptQualityUseCaseSpy: TranscriptQualityUseCase {
  private let shouldFail: Bool
  private(set) var publishCount = 0

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func optimize(
    timeline: TranscriptTimeline,
    localeIdentifier: String
  ) async throws -> (timeline: TranscriptTimeline, metadata: TranscriptVersionMetadata) {
    (
      timeline,
      TranscriptVersionMetadata(
        strategyID: "offline-readability",
        strategyVersion: "v1",
        modelName: "test",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
      )
    )
  }

  func optimizeAndPublish(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptVersionMetadata {
    publishCount += 1
    if shouldFail {
      throw TranscriptQualityAccessError.publicationFailed
    }
    return TranscriptVersionMetadata(
      strategyID: "offline-readability",
      strategyVersion: "v1",
      modelName: "test",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }
}

@MainActor
private final class MeetingAudioPlayerSpy: MeetingAudioPlayer {
  private(set) var loadedAssets: [MeetingAudioAsset] = []
  private(set) var seekPositions: [Double] = []
  private(set) var playCount = 0
  private(set) var unloadCount = 0
  private var state = MeetingAudioPlaybackSnapshot(
    durationSeconds: 0,
    currentSeconds: 0,
    isPlaying: false
  )

  func load(_ asset: MeetingAudioAsset) async throws -> MeetingAudioPlaybackSnapshot {
    loadedAssets.append(asset)
    state = MeetingAudioPlaybackSnapshot(
      durationSeconds: asset.durationSeconds,
      currentSeconds: 0,
      isPlaying: false
    )
    return state
  }

  func play() throws -> MeetingAudioPlaybackSnapshot {
    playCount += 1
    state = MeetingAudioPlaybackSnapshot(
      durationSeconds: state.durationSeconds,
      currentSeconds: state.currentSeconds,
      isPlaying: true
    )
    return state
  }

  func pause() -> MeetingAudioPlaybackSnapshot {
    state = MeetingAudioPlaybackSnapshot(
      durationSeconds: state.durationSeconds,
      currentSeconds: state.currentSeconds,
      isPlaying: false
    )
    return state
  }

  func seek(to seconds: Double) throws -> MeetingAudioPlaybackSnapshot {
    seekPositions.append(seconds)
    state = MeetingAudioPlaybackSnapshot(
      durationSeconds: state.durationSeconds,
      currentSeconds: seconds,
      isPlaying: state.isPlaying
    )
    return state
  }

  func snapshot() -> MeetingAudioPlaybackSnapshot {
    state
  }

  func unload() async {
    unloadCount += 1
  }
}

extension AuthoritativeDirectory {
  fileprivate static let fixture = Self(
    id: AuthoritativeDirectoryID(rawValue: "detail-test"),
    displayName: "Vault",
    kind: .userSelected
  )
}

extension MeetingIndexEntry {
  fileprivate static let fixture = Self(
    id: MeetingID(
      rawValue: UUID(uuidString: "672926A8-F2E9-4D84-A68F-DAB3F73E1FC1")!
    ),
    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
    relativeDirectory: "meeting-20270115-080000",
    assets: [.recording, .transcript],
    durationSeconds: 20
  )
}

extension MeetingDetail {
  fileprivate static let fixtureTimeline = try! TranscriptTimeline.normalizing(
    [
      TranscriptSegmentCandidate(
        startSeconds: 0,
        endSeconds: 10,
        text: "中文记录"
      ),
      TranscriptSegmentCandidate(
        startSeconds: 10,
        endSeconds: 20,
        text: "English note"
      ),
    ],
    audioDurationSeconds: 20
  )

  fileprivate static let fixtureOptimizedTimeline = try! TranscriptTimeline.normalizing(
    [
      TranscriptSegmentCandidate(
        startSeconds: 0,
        endSeconds: 10,
        text: "中文记录（优化）"
      ),
      TranscriptSegmentCandidate(
        startSeconds: 10,
        endSeconds: 20,
        text: "English note (optimized)"
      ),
    ],
    audioDurationSeconds: 20
  )

  fileprivate static let fixture = Self(
    meeting: .fixture,
    transcript: .available(fixtureTimeline),
    optimizedTranscript: .missing,
    recording: .available(
      MeetingAudioAsset(
        sourceID: MeetingAudioSourceID(rawValue: "test-recording"),
        durationSeconds: 20
      )
    ),
    minutes: .missing
  )

  fileprivate static let fixtureWithOptimized = Self(
    meeting: .fixture,
    transcript: .available(fixtureTimeline),
    optimizedTranscript: .available(fixtureOptimizedTimeline),
    recording: .available(
      MeetingAudioAsset(
        sourceID: MeetingAudioSourceID(rawValue: "test-recording"),
        durationSeconds: 20
      )
    ),
    minutes: .missing
  )
}
