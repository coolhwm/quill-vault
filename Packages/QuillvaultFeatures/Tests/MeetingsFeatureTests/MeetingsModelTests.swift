import Application
import Domain
import Foundation
import Testing

@testable import MeetingsFeature

@MainActor
@Suite("Meetings model")
struct MeetingsModelTests {
  @Test("Loads the cold-start library snapshot")
  func loadsSnapshot() async {
    let snapshot = MeetingLibrarySnapshot.fixture
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(restoreResult: .success(snapshot))
    )

    await model.load()

    #expect(model.state == .loaded(snapshot))
  }

  @Test(
    "Maps a stale bookmark to explicit reauthorization instead of another directory"
  )
  func staleBookmarkRecovery() async {
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkStale)
      )
    )

    await model.load()

    #expect(model.state == .failed(.renewAccess))
  }

  @Test("Maps a missing bookmark to initial directory selection")
  func missingBookmarkRecovery() async {
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.bookmarkMissing)
      )
    )

    await model.load()

    #expect(model.state == .failed(.chooseDirectory))
  }

  @Test("Maps an unavailable iCloud item to a download recovery")
  func iCloudDownloadRecovery() async {
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .failure(DirectoryAccessError.itemNotDownloaded)
      )
    )

    await model.load()

    #expect(model.state == .failed(.downloadRequired))
  }

  @Test("A recording-only meeting can retry its durable transcript job")
  func retryPendingTranscript() async {
    let recovery = TranscriptionRecoveryUseCaseStub()
    let model = makeModel(
      library: MeetingLibraryUseCaseStub(
        restoreResult: .success(.fixture)
      ),
      transcriptionRecovery: recovery
    )
    let meetingID = MeetingID(
      rawValue: UUID(uuidString: "5C46C983-86A7-4D39-B70D-0F42C917470C")!
    )

    await model.retryTranscript(meetingID: meetingID)

    #expect(await recovery.callCount == 1)
    #expect(model.recoveringMeetingID == nil)
    #expect(model.state == .loaded(.fixture))
  }

  private func makeModel(
    library: any MeetingLibraryUseCase,
    transcriptionRecovery: (any TranscriptionRecoveryUseCase)? = nil
  ) -> MeetingsModel {
    MeetingsModel(
      library: library,
      transcriptionRecovery: transcriptionRecovery,
      detail: UnusedMeetingDetailUseCase(),
      makePlayer: {
        UnusedMeetingAudioPlayer()
      }
    )
  }
}

private struct UnusedMeetingDetailUseCase: MeetingDetailUseCase {
  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    throw CancellationError()
  }
}

@MainActor
private final class UnusedMeetingAudioPlayer: MeetingAudioPlayer {
  private let snapshotValue = MeetingAudioPlaybackSnapshot(
    durationSeconds: 0,
    currentSeconds: 0,
    isPlaying: false
  )

  func load(_ asset: MeetingAudioAsset) async throws -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func play() throws -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func pause() -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func seek(to seconds: Double) throws -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func snapshot() -> MeetingAudioPlaybackSnapshot {
    snapshotValue
  }

  func unload() async {}
}

private actor TranscriptionRecoveryUseCaseStub: TranscriptionRecoveryUseCase {
  private(set) var callCount = 0

  func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    callCount += 1
    return []
  }
}

private struct MeetingLibraryUseCaseStub: MeetingLibraryUseCase {
  let restoreResult: Result<MeetingLibrarySnapshot, Error>

  func restore() async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    try restoreResult.get()
  }
}

extension MeetingLibrarySnapshot {
  fileprivate static let fixture = Self(
    directory: AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "test"),
      displayName: "Vault",
      kind: .userSelected
    ),
    meetings: [],
    diagnosticCount: 0
  )
}
