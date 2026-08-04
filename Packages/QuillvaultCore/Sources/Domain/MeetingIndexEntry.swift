import Foundation

public struct MeetingIndexEntry: Equatable, Sendable {
  public let id: MeetingID
  public let createdAt: Date
  public let relativeDirectory: String
  public let assets: MeetingAssetPresence
  public let title: String?
  public let durationSeconds: Double?
  public let modelName: String?
  public let transcriptRevisionID: String?
  public let transcriptFingerprint: String?
  public let minutesTranscriptRevisionID: String?
  public let minutesTranscriptFingerprint: String?
  public let minutesContentFingerprint: String?
  public let minutesGenerationJobID: UUID?

  public init(
    id: MeetingID,
    createdAt: Date,
    relativeDirectory: String,
    assets: MeetingAssetPresence,
    title: String? = nil,
    durationSeconds: Double? = nil,
    modelName: String? = nil,
    transcriptRevisionID: String? = nil,
    transcriptFingerprint: String? = nil,
    minutesTranscriptRevisionID: String? = nil,
    minutesTranscriptFingerprint: String? = nil,
    minutesContentFingerprint: String? = nil,
    minutesGenerationJobID: UUID? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.relativeDirectory = relativeDirectory
    self.assets = assets
    self.title = title
    self.durationSeconds = durationSeconds
    self.modelName = modelName
    self.transcriptRevisionID = transcriptRevisionID
    self.transcriptFingerprint = transcriptFingerprint
    self.minutesTranscriptRevisionID = minutesTranscriptRevisionID
    self.minutesTranscriptFingerprint = minutesTranscriptFingerprint
    self.minutesContentFingerprint = minutesContentFingerprint
    self.minutesGenerationJobID = minutesGenerationJobID
  }

  public var status: MeetingIndexStatus {
    if assets.contains(.minutes) {
      let freshnessMetadataMissing =
        transcriptRevisionID == nil
        || transcriptFingerprint == nil
        || minutesTranscriptRevisionID == nil
        || minutesTranscriptFingerprint == nil
      let fingerprintChanged =
        transcriptFingerprint != nil
        && minutesTranscriptFingerprint != nil
        && transcriptFingerprint != minutesTranscriptFingerprint
      let revisionChanged =
        transcriptRevisionID != nil
        && minutesTranscriptRevisionID != nil
        && transcriptRevisionID != minutesTranscriptRevisionID
      if freshnessMetadataMissing || fingerprintChanged || revisionChanged {
        return .minutesExpired
      }
      return .minutesCompleted
    }
    if assets.contains(.transcript) {
      return .awaitingMinutes
    }
    return .awaitingTranscript
  }

  /// Returns a copy with an updated list/detail title (e.g. after hand edit).
  public func withTitle(_ title: String?) -> MeetingIndexEntry {
    MeetingIndexEntry(
      id: id,
      createdAt: createdAt,
      relativeDirectory: relativeDirectory,
      assets: assets,
      title: title,
      durationSeconds: durationSeconds,
      modelName: modelName,
      transcriptRevisionID: transcriptRevisionID,
      transcriptFingerprint: transcriptFingerprint,
      minutesTranscriptRevisionID: minutesTranscriptRevisionID,
      minutesTranscriptFingerprint: minutesTranscriptFingerprint,
      minutesContentFingerprint: minutesContentFingerprint,
      minutesGenerationJobID: minutesGenerationJobID
    )
  }
}
