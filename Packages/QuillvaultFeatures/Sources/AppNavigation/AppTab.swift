public enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  case home
  case minutes
  case profile

  public var id: String { rawValue }

  public var systemImage: String {
    switch self {
    case .home:
      "house"
    case .minutes:
      "doc.text"
    case .profile:
      "person.crop.circle"
    }
  }
}
