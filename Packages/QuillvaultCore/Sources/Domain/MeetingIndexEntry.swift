import Foundation

public struct MeetingIndexEntry: Equatable, Sendable {
  public let id: MeetingID
  public let createdAt: Date
  public let relativeDirectory: String
  public let assets: MeetingAssetPresence

  public init(
    id: MeetingID,
    createdAt: Date,
    relativeDirectory: String,
    assets: MeetingAssetPresence
  ) {
    self.id = id
    self.createdAt = createdAt
    self.relativeDirectory = relativeDirectory
    self.assets = assets
  }
}
