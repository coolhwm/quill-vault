import CryptoKit
import Domain
import Foundation

public actor MeetingFileStore: AuthoritativeDirectoryAccess {
  private struct ResolvedRoot: Sendable {
    let url: URL
    let directory: AuthoritativeDirectory
  }

  private let dependencies: MeetingFileStoreDependencies
  private var resolvedRoots: [AuthoritativeDirectoryID: ResolvedRoot] = [:]

  public init() {
    dependencies = .live()
  }

  init(dependencies: MeetingFileStoreDependencies) {
    self.dependencies = dependencies
  }

  public func restoreSelectedDirectory() async throws -> AuthoritativeDirectory? {
    guard let data = await dependencies.bookmarkStore.load() else {
      return nil
    }
    let bookmark: ResolvedDirectoryBookmark
    do {
      bookmark = try dependencies.bookmarkCodec.resolve(data)
    } catch {
      throw DirectoryAccessError.bookmarkMissing
    }
    guard !bookmark.isStale else {
      throw DirectoryAccessError.bookmarkStale
    }
    let directory = selectedDirectory(url: bookmark.url, bookmark: data)
    resolvedRoots[directory.id] = ResolvedRoot(url: bookmark.url, directory: directory)
    return directory
  }

  public func resolveDefaultDirectory() async throws -> AuthoritativeDirectory {
    let url = try await dependencies.defaultDirectoryProvider.resolve()
    let directory = AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "icloud-default"),
      displayName: "Quillvault",
      kind: .iCloudDefault
    )
    resolvedRoots[directory.id] = ResolvedRoot(url: url, directory: directory)
    return directory
  }

  public func authorizeSelectedDirectory(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    guard
      let url = URL(string: selection.opaqueReference),
      url.isFileURL
    else {
      throw DirectoryAccessError.invalidSelection
    }
    guard await dependencies.scopeAccess.startAccessing(url) else {
      throw DirectoryAccessError.permissionDenied
    }
    guard isDirectory(url) else {
      await dependencies.scopeAccess.stopAccessing(url)
      throw DirectoryAccessError.invalidSelection
    }
    do {
      let bookmark = try dependencies.bookmarkCodec.create(for: url)
      try await dependencies.bookmarkStore.save(bookmark)
      await dependencies.scopeAccess.stopAccessing(url)
      let directory = selectedDirectory(url: url, bookmark: bookmark)
      resolvedRoots[directory.id] = ResolvedRoot(url: url, directory: directory)
      return directory
    } catch {
      await dependencies.scopeAccess.stopAccessing(url)
      throw DirectoryAccessError.permissionDenied
    }
  }

  public func scan(
    _ directory: AuthoritativeDirectory
  ) async throws -> MeetingDirectoryScan {
    guard let root = resolvedRoots[directory.id] else {
      throw DirectoryAccessError.directoryMoved
    }
    guard isDirectory(root.url) else {
      throw DirectoryAccessError.directoryMoved
    }
    if directory.kind == .userSelected {
      guard await dependencies.scopeAccess.startAccessing(root.url) else {
        throw DirectoryAccessError.permissionDenied
      }
      do {
        let result = try scanner.scan(root.url)
        await dependencies.scopeAccess.stopAccessing(root.url)
        return result
      } catch {
        await dependencies.scopeAccess.stopAccessing(root.url)
        throw error
      }
    }
    return try scanner.scan(root.url)
  }

  private var scanner: MeetingDirectoryScanner {
    MeetingDirectoryScanner(
      ubiquitousStatus: dependencies.ubiquitousStatus
    )
  }

  private func selectedDirectory(
    url: URL,
    bookmark: Data
  ) -> AuthoritativeDirectory {
    let digest = SHA256.hash(data: bookmark)
      .prefix(16)
      .map { String(format: "%02x", $0) }
      .joined()
    return AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: "selected-\(digest)"),
      displayName: url.lastPathComponent,
      kind: .userSelected
    )
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: url.path,
      isDirectory: &isDirectory
    ) && isDirectory.boolValue
  }
}
