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
  fileprivate static let fixture = Self(
    meeting: .fixture,
    transcript: .available(
      try! TranscriptTimeline.normalizing(
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
    ),
    recording: .available(
      MeetingAudioAsset(
        sourceID: MeetingAudioSourceID(rawValue: "test-recording"),
        durationSeconds: 20
      )
    ),
    minutes: .missing
  )
}
