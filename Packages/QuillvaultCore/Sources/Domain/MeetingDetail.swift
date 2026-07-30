import Foundation

public struct MeetingAudioSourceID: Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct MeetingAudioAsset: Equatable, Sendable {
  public let sourceID: MeetingAudioSourceID
  public let durationSeconds: Double

  public init(
    sourceID: MeetingAudioSourceID,
    durationSeconds: Double
  ) {
    self.sourceID = sourceID
    self.durationSeconds = durationSeconds
  }
}

public enum MeetingTranscriptAsset: Equatable, Sendable {
  case available(TranscriptTimeline)
  case missing
  case downloadRequired
  case unreadable
}

public enum MeetingRecordingAsset: Equatable, Sendable {
  case available(MeetingAudioAsset)
  case missing
  case downloadRequired
  case unreadable
}

public struct MeetingMinutesContent: Equatable, Sendable {
  public let summaryMarkdown: String
  public let diagramSource: String?

  public init(summaryMarkdown: String, diagramSource: String?) {
    self.summaryMarkdown = summaryMarkdown
    self.diagramSource = diagramSource
  }
}

public enum MeetingMarkdownAsset: Equatable, Sendable {
  case available(MeetingMinutesContent)
  case missing
  case downloadRequired
  case unreadable
}

public struct MeetingDetail: Equatable, Sendable {
  public let meeting: MeetingIndexEntry
  public let transcript: MeetingTranscriptAsset
  public let recording: MeetingRecordingAsset
  public let minutes: MeetingMarkdownAsset

  public init(
    meeting: MeetingIndexEntry,
    transcript: MeetingTranscriptAsset,
    recording: MeetingRecordingAsset,
    minutes: MeetingMarkdownAsset
  ) {
    self.meeting = meeting
    self.transcript = transcript
    self.recording = recording
    self.minutes = minutes
  }
}

public protocol MeetingDetailAccess: Sendable {
  func loadMeetingDetail(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail
}

public struct MeetingAudioPlaybackSnapshot: Equatable, Sendable {
  public let durationSeconds: Double
  public let currentSeconds: Double
  public let isPlaying: Bool

  public init(
    durationSeconds: Double,
    currentSeconds: Double,
    isPlaying: Bool
  ) {
    self.durationSeconds = durationSeconds
    self.currentSeconds = currentSeconds
    self.isPlaying = isPlaying
  }
}

public enum MeetingAudioPlaybackError: Error, Equatable, Sendable {
  case unavailable
  case unreadable
  case playbackFailed
}

@MainActor
public protocol MeetingAudioPlayer: AnyObject {
  func load(_ asset: MeetingAudioAsset) async throws -> MeetingAudioPlaybackSnapshot
  func play() throws -> MeetingAudioPlaybackSnapshot
  func pause() -> MeetingAudioPlaybackSnapshot
  func seek(to seconds: Double) throws -> MeetingAudioPlaybackSnapshot
  func snapshot() -> MeetingAudioPlaybackSnapshot
  func unload() async
}
