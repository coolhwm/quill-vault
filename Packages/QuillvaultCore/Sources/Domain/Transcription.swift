import Foundation

public struct AudioFrame: Equatable, Sendable {
  public let samples: Data
  public let sampleRate: Double
  public let channelCount: Int
  public let frameCount: Int
  public let startSeconds: Double

  public init(
    samples: Data,
    sampleRate: Double,
    channelCount: Int,
    frameCount: Int,
    startSeconds: Double
  ) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCount = frameCount
    self.startSeconds = startSeconds
  }
}

public enum SpeechRecognitionStability: Equatable, Sendable {
  case volatile
  case final
}

public struct SpeechRecognitionEvent: Equatable, Sendable {
  public let segment: TranscriptSegmentCandidate
  public let stability: SpeechRecognitionStability

  public init(
    segment: TranscriptSegmentCandidate,
    stability: SpeechRecognitionStability
  ) {
    self.segment = segment
    self.stability = stability
  }
}

public typealias SpeechRecognitionStream =
  AsyncThrowingStream<SpeechRecognitionEvent, any Error>

public protocol SpeechTranscriptionEngine: Sendable {
  func liveResults(
    frames: AsyncStream<AudioFrame>,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream

  func fileResults(
    at recordingURL: URL,
    localeIdentifier: String
  ) async throws -> SpeechRecognitionStream
}

public struct TranscriptionJob: Equatable, Codable, Sendable {
  public let meetingID: MeetingID
  public let recordingURL: URL
  public let audioDurationSeconds: Double
  public let localeIdentifier: String

  public init(
    meetingID: MeetingID,
    recordingURL: URL,
    audioDurationSeconds: Double,
    localeIdentifier: String
  ) {
    self.meetingID = meetingID
    self.recordingURL = recordingURL
    self.audioDurationSeconds = audioDurationSeconds
    self.localeIdentifier = localeIdentifier
  }
}

public protocol TranscriptionJobStore: Sendable {
  func savePending(_ job: TranscriptionJob) async throws
  func pendingJobs() async throws -> [TranscriptionJob]
  func markPublished(
    meetingID: MeetingID,
    revision: TranscriptRevision
  ) async throws
}

public protocol TranscriptionRecoverySource: Sendable {
  func recoverableTranscriptionJobs(
    localeIdentifier: String
  ) async throws -> [TranscriptionJob]
}

public protocol RecordingAssetAccess: Sendable {
  func beginTranscriptionAccess(
    meetingID: MeetingID,
    recordingURL: URL
  ) async throws -> URL

  func endTranscriptionAccess(meetingID: MeetingID) async
}

public protocol TranscriptPublisher: Sendable {
  func appendFinal(
    _ segment: TranscriptSegmentCandidate,
    meetingID: MeetingID,
    recordingURL: URL
  ) async throws

  func publish(
    _ revision: TranscriptRevision,
    recordingURL: URL
  ) async throws -> TranscriptRevision
}
