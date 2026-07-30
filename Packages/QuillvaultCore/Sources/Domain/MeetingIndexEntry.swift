import Foundation

public struct MeetingIndexEntry: Equatable, Sendable {
  public let id: MeetingID
  public let createdAt: Date
  public let relativeDirectory: String
  public let assets: MeetingAssetPresence
  public let title: String?
  public let durationSeconds: Double?
  public let modelName: String?

  public init(
    id: MeetingID,
    createdAt: Date,
    relativeDirectory: String,
    assets: MeetingAssetPresence,
    title: String? = nil,
    durationSeconds: Double? = nil,
    modelName: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.relativeDirectory = relativeDirectory
    self.assets = assets
    self.title = title
    self.durationSeconds = durationSeconds
    self.modelName = modelName
  }

  public var status: MeetingIndexStatus {
    if assets.contains(.minutes) {
      return .minutesCompleted
    }
    if assets.contains(.transcript) {
      return .awaitingMinutes
    }
    return .awaitingTranscript
  }
}
