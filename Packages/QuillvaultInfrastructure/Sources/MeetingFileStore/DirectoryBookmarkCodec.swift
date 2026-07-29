import Foundation

struct ResolvedDirectoryBookmark: Sendable {
  let url: URL
  let isStale: Bool
}

protocol DirectoryBookmarkCoding: Sendable {
  func create(for url: URL) throws -> Data
  func resolve(_ data: Data) throws -> ResolvedDirectoryBookmark
}

struct FoundationDirectoryBookmarkCodec: DirectoryBookmarkCoding {
  func create(for url: URL) throws -> Data {
    #if os(macOS)
      return try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    #else
      return try url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    #endif
  }

  func resolve(_ data: Data) throws -> ResolvedDirectoryBookmark {
    var stale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
      let options: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif
    let url = try URL(
      resolvingBookmarkData: data,
      options: options,
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return ResolvedDirectoryBookmark(url: url, isStale: stale)
  }
}

struct PlainDirectoryBookmarkCodec: DirectoryBookmarkCoding {
  func create(for url: URL) -> Data {
    Data(url.absoluteString.utf8)
  }

  func resolve(_ data: Data) throws -> ResolvedDirectoryBookmark {
    guard
      let value = String(data: data, encoding: .utf8),
      let url = URL(string: value)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return ResolvedDirectoryBookmark(url: url, isStale: false)
  }
}
