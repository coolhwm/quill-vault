import Foundation

public struct MeetingID: Hashable, Codable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}
