import Foundation

protocol UbiquitousItemStatusChecking: Sendable {
  func isDownloaded(_ url: URL) throws -> Bool
}

struct FoundationUbiquitousItemStatusChecker: UbiquitousItemStatusChecking {
  func isDownloaded(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [
      .isUbiquitousItemKey,
      .ubiquitousItemDownloadingStatusKey,
    ])
    guard values.isUbiquitousItem == true else {
      return true
    }
    return values.ubiquitousItemDownloadingStatus == .current
  }
}

struct AlwaysDownloadedItemStatusChecker: UbiquitousItemStatusChecking {
  func isDownloaded(_ url: URL) -> Bool {
    true
  }
}
