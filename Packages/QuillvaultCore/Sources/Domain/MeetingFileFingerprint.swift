import Foundation

public struct MeetingFileFingerprint: Equatable, Sendable {
  public let meetingID: MeetingID
  public let asset: MeetingAsset
  public let byteCount: Int64
  public let modifiedAt: Date
  public let opaqueDigest: String

  public init(
    meetingID: MeetingID,
    asset: MeetingAsset,
    byteCount: Int64,
    modifiedAt: Date,
    opaqueDigest: String
  ) {
    self.meetingID = meetingID
    self.asset = asset
    self.byteCount = byteCount
    self.modifiedAt = modifiedAt
    self.opaqueDigest = opaqueDigest
  }
}
