import Foundation

struct MeetingFileStoreDependencies: Sendable {
  let defaultDirectoryProvider: any DefaultDirectoryProviding
  let bookmarkStore: any DirectoryBookmarkStoring
  let bookmarkCodec: any DirectoryBookmarkCoding
  let scopeAccess: any SecurityScopedResourceAccessing
  let ubiquitousStatus: any UbiquitousItemStatusChecking

  static func live() -> Self {
    Self(
      defaultDirectoryProvider: ICloudDefaultDirectoryProvider(),
      bookmarkStore: UserDefaultsDirectoryBookmarkStore(),
      bookmarkCodec: FoundationDirectoryBookmarkCodec(),
      scopeAccess: FoundationSecurityScopedResourceAccess(),
      ubiquitousStatus: FoundationUbiquitousItemStatusChecker()
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
      AlwaysDownloadedItemStatusChecker()
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
      ubiquitousStatus: ubiquitousStatus
    )
  }
}
