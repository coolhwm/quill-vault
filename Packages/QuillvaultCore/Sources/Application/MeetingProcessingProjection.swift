import Domain
import Foundation

/// User-visible processing phase for one meeting, derived from index + jobs.
/// Home, list, and detail share this projection so multi-meeting work does not
/// collide on a single global focused phase.
public enum MeetingProcessingPhase: Equatable, Sendable {
  case awaitingTranscript
  case finalizingTranscript
  case transcriptFailed
  case optimizingTranscript
  case optimizeFailed
  case awaitingMinutes
  case generatingMinutes(
    progress: Int,
    completedChunks: Int,
    chunkCount: Int,
    stage: GenerationStage
  )
  case generationPaused(
    progress: Int,
    pauseReason: GenerationPauseReason?
  )
  case minutesCompleted
  case minutesExpired
  case generationFailed
  case idle

  public var isActivelyProcessing: Bool {
    switch self {
    case .finalizingTranscript, .optimizingTranscript, .generatingMinutes, .generationPaused:
      return true
    case .awaitingTranscript, .transcriptFailed, .optimizeFailed, .awaitingMinutes,
      .minutesCompleted, .minutesExpired, .generationFailed, .idle:
      return false
    }
  }

  public var showsOnHomeProcessingList: Bool {
    switch self {
    case .idle, .minutesCompleted:
      return false
    case .awaitingTranscript, .finalizingTranscript, .transcriptFailed,
      .optimizingTranscript, .optimizeFailed, .awaitingMinutes,
      .generatingMinutes, .generationPaused, .minutesExpired, .generationFailed:
      return true
    }
  }

  public var progressPercent: Int? {
    switch self {
    case .generatingMinutes(let progress, _, _, _):
      return progress
    case .generationPaused(let progress, _):
      return progress
    default:
      return nil
    }
  }
}

public struct MeetingProcessingItem: Equatable, Sendable, Identifiable {
  public var id: MeetingID { meetingID }
  public let meetingID: MeetingID
  public let title: String?
  public let createdAt: Date
  public let durationSeconds: Double?
  public let phase: MeetingProcessingPhase

  public init(
    meetingID: MeetingID,
    title: String?,
    createdAt: Date,
    durationSeconds: Double?,
    phase: MeetingProcessingPhase
  ) {
    self.meetingID = meetingID
    self.title = title
    self.createdAt = createdAt
    self.durationSeconds = durationSeconds
    self.phase = phase
  }
}

/// Pure projector: index entry + optional active generation job (+ local
/// home-only overrides for transcript/optimize stages not yet on disk).
public enum MeetingProcessingProjector {
  public static func project(
    meeting: MeetingIndexEntry,
    generation: GenerationSnapshot? = nil,
    localOverride: MeetingProcessingPhase? = nil
  ) -> MeetingProcessingPhase {
    if let localOverride {
      switch localOverride {
      case .finalizingTranscript, .transcriptFailed, .optimizingTranscript, .optimizeFailed:
        return localOverride
      default:
        break
      }
    }

    if let generation, generation.job.isActive {
      switch generation.job.state {
      case .pending, .running:
        return .generatingMinutes(
          progress: generation.job.progress,
          completedChunks: generation.job.completedChunkCount,
          chunkCount: generation.job.chunkCount,
          stage: generation.job.stage
        )
      case .paused:
        return .generationPaused(
          progress: generation.job.progress,
          pauseReason: generation.job.pauseReason
        )
      case .completed, .superseded:
        break
      }
    }

    if let localOverride {
      switch localOverride {
      case .generationFailed:
        return localOverride
      default:
        break
      }
    }

    switch meeting.status {
    case .awaitingTranscript:
      return .awaitingTranscript
    case .awaitingMinutes:
      return .awaitingMinutes
    case .minutesCompleted:
      return .minutesCompleted
    case .minutesExpired:
      return .minutesExpired
    }
  }

  /// Merge library meetings with active generation jobs and optional local
  /// home overrides keyed by meeting ID.
  public static func projectAll(
    meetings: [MeetingIndexEntry],
    generationsByMeeting: [MeetingID: GenerationSnapshot],
    localOverrides: [MeetingID: MeetingProcessingPhase] = [:]
  ) -> [MeetingProcessingItem] {
    var seen = Set<MeetingID>()
    var items: [MeetingProcessingItem] = []

    for meeting in meetings {
      seen.insert(meeting.id)
      let phase = project(
        meeting: meeting,
        generation: generationsByMeeting[meeting.id],
        localOverride: localOverrides[meeting.id]
      )
      items.append(
        MeetingProcessingItem(
          meetingID: meeting.id,
          title: meeting.title,
          createdAt: meeting.createdAt,
          durationSeconds: meeting.durationSeconds,
          phase: phase
        )
      )
    }

    // Active jobs whose meeting is temporarily missing from the library index.
    for (meetingID, snapshot) in generationsByMeeting where !seen.contains(meetingID) {
      guard snapshot.job.isActive else { continue }
      let phase = project(
        meeting: MeetingIndexEntry(
          id: meetingID,
          createdAt: snapshot.job.createdAt,
          relativeDirectory: meetingID.rawValue.uuidString,
          assets: [.transcript]
        ),
        generation: snapshot,
        localOverride: localOverrides[meetingID]
      )
      items.append(
        MeetingProcessingItem(
          meetingID: meetingID,
          title: nil,
          createdAt: snapshot.job.createdAt,
          durationSeconds: nil,
          phase: phase
        )
      )
    }

    return items.sorted { $0.createdAt > $1.createdAt }
  }

  public static func homeVisibleItems(
    from items: [MeetingProcessingItem]
  ) -> [MeetingProcessingItem] {
    items.filter { $0.phase.showsOnHomeProcessingList }
  }
}
