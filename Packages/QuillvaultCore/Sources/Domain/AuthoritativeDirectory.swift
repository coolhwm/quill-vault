public struct AuthoritativeDirectoryID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum AuthoritativeDirectoryKind: String, Codable, Sendable {
  case iCloudDefault
  case userSelected
}

public struct AuthoritativeDirectory: Equatable, Sendable {
  public let id: AuthoritativeDirectoryID
  public let displayName: String
  public let kind: AuthoritativeDirectoryKind

  public init(
    id: AuthoritativeDirectoryID,
    displayName: String,
    kind: AuthoritativeDirectoryKind
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
  }
}
