import Domain
import Foundation
import Testing

@testable import Application

@Suite("Meeting processing projection")
struct MeetingProcessingProjectionTests {
  private let idA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
  private let idB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
  private let idOpt = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
  private let idDone = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
  private let idRun = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
  private let idAwait = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!

  @Test("Two meetings keep independent generation progress")
  func dualMeetingIndependentPhases() {
    let meetingA = indexEntry(
      id: idA,
      statusAssets: [.transcript],
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let meetingB = indexEntry(
      id: idB,
      statusAssets: [.transcript, .minutes],
      createdAt: Date(timeIntervalSince1970: 200)
    )
    let genA = snapshot(
      meetingID: meetingA.id,
      state: .running,
      progress: 40,
      chunks: (1, 4)
    )
    let genB = snapshot(
      meetingID: meetingB.id,
      state: .paused,
      progress: 70,
      chunks: (2, 3),
      pauseReason: .networkUnavailable
    )

    let items = MeetingProcessingProjector.projectAll(
      meetings: [meetingA, meetingB],
      generationsByMeeting: [
        meetingA.id: genA,
        meetingB.id: genB,
      ]
    )

    #expect(items.count == 2)
    let phaseA = items.first { $0.meetingID == meetingA.id }?.phase
    let phaseB = items.first { $0.meetingID == meetingB.id }?.phase
    #expect(
      phaseA
        == .generatingMinutes(
          progress: 40,
          completedChunks: 1,
          chunkCount: 4,
          stage: .summarizing
        )
    )
    #expect(
      phaseB
        == .generationPaused(progress: 70, pauseReason: .networkUnavailable)
    )
  }

  @Test("Local optimize override wins over awaiting minutes")
  func localOptimizeOverride() {
    let meeting = indexEntry(
      id: idOpt,
      statusAssets: [.transcript],
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let phase = MeetingProcessingProjector.project(
      meeting: meeting,
      generation: nil,
      localOverride: .optimizingTranscript
    )
    #expect(phase == .optimizingTranscript)
  }

  @Test("Home list hides idle completed meetings")
  func homeVisibleFiltersCompleted() {
    let completed = MeetingProcessingItem(
      meetingID: MeetingID(rawValue: idDone),
      title: "Done",
      createdAt: Date(timeIntervalSince1970: 2),
      durationSeconds: 10,
      phase: .minutesCompleted
    )
    let running = MeetingProcessingItem(
      meetingID: MeetingID(rawValue: idRun),
      title: "Run",
      createdAt: Date(timeIntervalSince1970: 3),
      durationSeconds: 20,
      phase: .generatingMinutes(
        progress: 10,
        completedChunks: 0,
        chunkCount: 1,
        stage: .pending
      )
    )
    let visible = MeetingProcessingProjector.homeVisibleItems(from: [
      completed, running,
    ])
    #expect(visible.map(\.meetingID.rawValue) == [idRun])
  }

  @Test("Index status drives list when no active job")
  func indexOnlyProjection() {
    let awaiting = indexEntry(
      id: idAwait,
      statusAssets: [.transcript],
      createdAt: Date()
    )
    #expect(
      MeetingProcessingProjector.project(meeting: awaiting) == .awaitingMinutes
    )
    let done = indexEntry(
      id: idDone,
      statusAssets: [.transcript, .minutes],
      createdAt: Date(),
      transcriptFP: "a",
      minutesFP: "a"
    )
    #expect(
      MeetingProcessingProjector.project(meeting: done) == .minutesCompleted
    )
  }

  private func indexEntry(
    id: UUID,
    statusAssets: MeetingAssetPresence,
    createdAt: Date,
    transcriptFP: String? = "t1",
    minutesFP: String? = nil
  ) -> MeetingIndexEntry {
    MeetingIndexEntry(
      id: MeetingID(rawValue: id),
      createdAt: createdAt,
      relativeDirectory: id.uuidString,
      assets: statusAssets,
      title: id.uuidString,
      durationSeconds: 60,
      transcriptRevisionID: statusAssets.contains(.transcript) ? "rev" : nil,
      transcriptFingerprint: statusAssets.contains(.transcript) ? transcriptFP : nil,
      minutesTranscriptRevisionID: statusAssets.contains(.minutes) ? "rev" : nil,
      minutesTranscriptFingerprint: statusAssets.contains(.minutes)
        ? (minutesFP ?? transcriptFP) : nil,
      minutesContentFingerprint: statusAssets.contains(.minutes) ? "m" : nil
    )
  }

  private func snapshot(
    meetingID: MeetingID,
    state: GenerationJobState,
    progress: Int,
    chunks: (Int, Int),
    pauseReason: GenerationPauseReason? = nil
  ) -> GenerationSnapshot {
    GenerationSnapshot(
      job: GenerationJob(
        id: UUID(),
        meetingID: meetingID,
        transcriptRevisionID: "rev",
        transcriptFingerprint: "fp",
        modelProfile: ModelProfileSnapshot(
          profileID: ModelProfileID(rawValue: UUID()),
          baseURL: URL(string: "https://example.com")!,
          model: "m",
          parameters: ModelGenerationParameters(),
          credentialReference: ModelCredentialReference(rawValue: UUID())
        ),
        chunkCount: chunks.1,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        state: state,
        stage: .summarizing,
        progress: progress,
        completedChunkCount: chunks.0,
        pauseReason: pauseReason
      )
    )
  }
}
