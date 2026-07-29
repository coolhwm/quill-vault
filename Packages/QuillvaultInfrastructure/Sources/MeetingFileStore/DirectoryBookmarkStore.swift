import Foundation

protocol DirectoryBookmarkStoring: Sendable {
  func load() async -> Data?
  func save(_ data: Data) async throws
}

actor UserDefaultsDirectoryBookmarkStore: DirectoryBookmarkStoring {
  private let suiteName: String?
  private let key: String

  init(
    suiteName: String? = nil,
    key: String = "authoritative-directory-bookmark"
  ) {
    self.suiteName = suiteName
    self.key = key
  }

  func load() -> Data? {
    userDefaults.data(forKey: key)
  }

  func save(_ data: Data) {
    userDefaults.set(data, forKey: key)
  }

  private var userDefaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}
