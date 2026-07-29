public enum MeetingAsset: String, CaseIterable, Codable, Sendable {
  case recording
  case transcript
  case minutes
}

public struct MeetingAssetPresence: OptionSet, Equatable, Codable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let recording = Self(rawValue: 1 << 0)
  public static let transcript = Self(rawValue: 1 << 1)
  public static let minutes = Self(rawValue: 1 << 2)
}
