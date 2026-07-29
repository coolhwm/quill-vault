import Foundation

struct MeetingFileStoreDependencies: Sendable {
  let defaultDirectoryProvider: any DefaultDirectoryProviding
  let bookmarkStore: any DirectoryBookmarkStoring
  let bookmarkCodec: any DirectoryBookmarkCoding
  let scopeAccess: any SecurityScopedResourceAccessing
  let ubiquitousStatus: any UbiquitousItemStatusChecking
  let minimumRecordingCapacityBytes: Int64
  let availableCapacity: @Sendable (URL) throws -> Int64?

  static func live() -> Self {
    Self(
      defaultDirectoryProvider: ICloudDefaultDirectoryProvider(),
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
    defaultDirectory: URL? = nil,
    defaultDirectoryProvider: (any DefaultDirectoryProviding)? = nil,
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
    let resolvedDefaultDirectoryProvider: any DefaultDirectoryProviding
    if let defaultDirectoryProvider {
      resolvedDefaultDirectoryProvider = defaultDirectoryProvider
    } else if let defaultDirectory {
      resolvedDefaultDirectoryProvider = FixedDefaultDirectoryProvider(
        url: defaultDirectory
      )
    } else {
      preconditionFailure(
        "Tests must provide either defaultDirectory or defaultDirectoryProvider"
      )
    }

    return Self(
      defaultDirectoryProvider: resolvedDefaultDirectoryProvider,
      bookmarkStore: bookmarkStore
        ?? UserDefaultsDirectoryBookmarkStore(
          suiteName: UUID().uuidString
        ),
      bookmarkCodec: bookmarkCodec,
      scopeAccess: scopeAccess,
      ubiquitousStatus: ubiquitousStatus,
      minimumRecordingCapacityBytes: minimumRecordingCapacityBytes,
      availableCapacity: availableCapacity
    )
  }
}
