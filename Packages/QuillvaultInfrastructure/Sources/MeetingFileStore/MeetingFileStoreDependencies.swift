import Foundation

struct MeetingFileStoreDependencies: Sendable {
  let bookmarkStore: any DirectoryBookmarkStoring
  let bookmarkCodec: any DirectoryBookmarkCoding
  let scopeAccess: any SecurityScopedResourceAccessing
  let ubiquitousStatus: any UbiquitousItemStatusChecking
  let minimumRecordingCapacityBytes: Int64
  let availableCapacity: @Sendable (URL) throws -> Int64?

  static func live() -> Self {
    Self(
      bookmarkStore: UserDefaultsDirectoryBookmarkStore(),
      bookmarkCodec: FoundationDirectoryBookmarkCodec(),
      scopeAccess: FoundationSecurityScopedResourceAccess(),
      ubiquitousStatus: FoundationUbiquitousItemStatusChecker(),
      minimumRecordingCapacityBytes: 512 * 1_024 * 1_024,
      availableCapacity: { url in
        try url.resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
      }
    )
  }

  static func testing(
    authorizedDirectory: URL? = nil,
    bookmarkStore: (any DirectoryBookmarkStoring)? = nil,
    bookmarkCodec: any DirectoryBookmarkCoding = PlainDirectoryBookmarkCodec(),
    scopeAccess: any SecurityScopedResourceAccessing =
      AlwaysGrantedSecurityScopedResourceAccess(),
    ubiquitousStatus: any UbiquitousItemStatusChecking =
      AlwaysDownloadedItemStatusChecker(),
    minimumRecordingCapacityBytes: Int64 = 512 * 1_024 * 1_024,
    availableCapacity: @escaping @Sendable (URL) throws -> Int64? = { _ in
      Int64.max
    }
  ) -> Self {
    let resolvedBookmarkStore: any DirectoryBookmarkStoring
    if let bookmarkStore {
      resolvedBookmarkStore = bookmarkStore
    } else if let authorizedDirectory {
      resolvedBookmarkStore = FixedDirectoryBookmarkStore(
        data: try! bookmarkCodec.create(for: authorizedDirectory)
      )
    } else {
      resolvedBookmarkStore = UserDefaultsDirectoryBookmarkStore(
        suiteName: UUID().uuidString
      )
    }

    return Self(
      bookmarkStore: resolvedBookmarkStore,
      bookmarkCodec: bookmarkCodec,
      scopeAccess: scopeAccess,
      ubiquitousStatus: ubiquitousStatus,
      minimumRecordingCapacityBytes: minimumRecordingCapacityBytes,
      availableCapacity: availableCapacity
    )
  }
}

private actor FixedDirectoryBookmarkStore: DirectoryBookmarkStoring {
  private var data: Data?

  init(data: Data) {
    self.data = data
  }

  func load() -> Data? {
    data
  }

  func save(_ data: Data) {
    self.data = data
  }
}
