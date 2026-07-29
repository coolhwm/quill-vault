import Foundation

protocol SecurityScopedResourceAccessing: Sendable {
  func startAccessing(_ url: URL) async -> Bool
  func stopAccessing(_ url: URL) async
}

struct FoundationSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
  func startAccessing(_ url: URL) async -> Bool {
    url.startAccessingSecurityScopedResource()
  }

  func stopAccessing(_ url: URL) async {
    url.stopAccessingSecurityScopedResource()
  }
}

struct AlwaysGrantedSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
  func startAccessing(_ url: URL) async -> Bool {
    true
  }

  func stopAccessing(_ url: URL) async {}
}
