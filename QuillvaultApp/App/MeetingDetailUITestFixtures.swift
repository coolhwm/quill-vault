import Application
import Domain
import Foundation

struct UITestMeetingDetailUseCase: MeetingDetailUseCase {
  static let meetingID = MeetingID(
    rawValue: UUID(uuidString: "EBD72F04-E276-4590-A7F4-B0DA07685418")!
  )
  static let directory = AuthoritativeDirectory(
    id: AuthoritativeDirectoryID(rawValue: "ui-test-directory"),
    displayName: "UI Test Vault",
    kind: .userSelected
  )
  static let meeting = MeetingIndexEntry(
    id: meetingID,
    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
    relativeDirectory: "meeting-20270115-080000",
    assets: [.recording, .transcript],
    durationSeconds: 60
  )
  static let librarySnapshot = MeetingLibrarySnapshot(
    directory: directory,
    meetings: [meeting],
    diagnosticCount: 0
  )

  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    if ProcessInfo.processInfo.arguments.contains(
      "-ui-test-meeting-detail-empty"
    ) {
      return MeetingDetail(
        meeting: meeting,
        transcript: .available(
          try TranscriptTimeline.normalizing(
            [],
            audioDurationSeconds: 60
          )
        ),
        recording: .missing,
        minutes: .available(
          MeetingMinutesContent(
            summaryMarkdown: "",
            diagramSource: nil
          )
        )
      )
    }
    if ProcessInfo.processInfo.arguments.contains("-ui-test-meeting-minutes") {
      return MeetingDetail(
        meeting: meeting,
        transcript: .available(
          try TranscriptTimeline.normalizing(
            [
              TranscriptSegmentCandidate(
                startSeconds: 0,
                endSeconds: 1,
                text: "会议决定保留现有方案。"
              )
            ],
            audioDurationSeconds: 60
          )
        ),
        recording: .available(
          MeetingAudioAsset(
            sourceID: MeetingAudioSourceID(rawValue: "ui-test-recording"),
            durationSeconds: 60
          )
        ),
        minutes: .available(
          MeetingMinutesContent(
            summaryMarkdown: "# 会议纪要\n\n## 决策\n保留现有方案。",
            diagramSource: "flowchart TD\n  A[讨论] --> B[决定]",
            informationMayBeIncomplete: true
          )
        )
      )
    }
    let candidates = (0..<60).map { index in
      TranscriptSegmentCandidate(
        startSeconds: Double(index),
        endSeconds: Double(index + 1),
        text: index.isMultiple(of: 2)
          ? "第 \(index + 1) 段文字记录"
          : "English segment \(index + 1)"
      )
    }
    return MeetingDetail(
      meeting: meeting,
      transcript: .available(
        try TranscriptTimeline.normalizing(
          candidates,
          audioDurationSeconds: 60
        )
      ),
      recording: .available(
        MeetingAudioAsset(
          sourceID: MeetingAudioSourceID(rawValue: "ui-test-recording"),
          durationSeconds: 60
        )
      ),
      minutes: .missing
    )
  }
}

@MainActor
final class UITestMeetingAudioPlayer: MeetingAudioPlayer {
  private var playback = MeetingAudioPlaybackSnapshot(
    durationSeconds: 0,
    currentSeconds: 0,
    isPlaying: false
  )

  func load(_ asset: MeetingAudioAsset) async throws -> MeetingAudioPlaybackSnapshot {
    playback = MeetingAudioPlaybackSnapshot(
      durationSeconds: asset.durationSeconds,
      currentSeconds: 0,
      isPlaying: false
    )
    return playback
  }

  func play() throws -> MeetingAudioPlaybackSnapshot {
    playback = MeetingAudioPlaybackSnapshot(
      durationSeconds: playback.durationSeconds,
      currentSeconds: playback.currentSeconds,
      isPlaying: true
    )
    return playback
  }

  func pause() -> MeetingAudioPlaybackSnapshot {
    playback = MeetingAudioPlaybackSnapshot(
      durationSeconds: playback.durationSeconds,
      currentSeconds: playback.currentSeconds,
      isPlaying: false
    )
    return playback
  }

  func seek(to seconds: Double) throws -> MeetingAudioPlaybackSnapshot {
    playback = MeetingAudioPlaybackSnapshot(
      durationSeconds: playback.durationSeconds,
      currentSeconds: seconds,
      isPlaying: playback.isPlaying
    )
    return playback
  }

  func snapshot() -> MeetingAudioPlaybackSnapshot {
    playback
  }

  func unload() async {
    playback = MeetingAudioPlaybackSnapshot(
      durationSeconds: 0,
      currentSeconds: 0,
      isPlaying: false
    )
  }
}
