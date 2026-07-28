import Foundation

// MARK: - Models

struct AuthoritativeDirectoryInfo: Equatable, Sendable {
    let displayName: String
    let pathDescription: String
    let isAccessible: Bool
}

enum AuthoritativeDirectoryState: Equatable, Sendable {
    case unset
    case ready(AuthoritativeDirectoryInfo)
    case needsReauthorization(String)

    var isWritable: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum AuthoritativeDirectoryError: LocalizedError, Equatable {
    case notSelected
    case bookmarkInvalid(String)
    case accessDenied
    case notADirectory

    var errorDescription: String? {
        switch self {
        case .notSelected:
            "尚未选择权威目录。请通过系统文件夹选择器指定 iCloud Drive 或 Obsidian 目录。"
        case let .bookmarkInvalid(detail):
            "权威目录授权已失效：\(detail)。请重新选择目录；不会回退到 App 沙盒隐藏副本。"
        case .accessDenied:
            "无法访问所选权威目录。请重新授权选择。"
        case .notADirectory:
            "所选位置不是文件夹。"
        }
    }
}

// MARK: - Boundaries

@MainActor
protocol BookmarkDataStoring: AnyObject {
    func save(_ data: Data) throws
    func load() throws -> Data?
    func clear() throws
}

@MainActor
protocol SecurityScopedBookmarking: AnyObject {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

// MARK: - In-memory / controlled

@MainActor
final class InMemoryBookmarkStore: BookmarkDataStoring {
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func save(_ data: Data) throws {
        self.data = data
    }

    func load() throws -> Data? {
        data
    }

    func clear() throws {
        data = nil
    }
}

/// Maps opaque bookmark Data to sandboxed temp directories for unit tests.
@MainActor
final class ControllableBookmarking: SecurityScopedBookmarking {
    private var registry: [Data: URL] = [:]
    private var staleKeys: Set<Data> = []
    private var inaccessibleKeys: Set<Data> = []

    func register(_ url: URL, as bookmark: Data, stale: Bool = false, inaccessible: Bool = false) {
        registry[bookmark] = url
        if stale { staleKeys.insert(bookmark) }
        if inaccessible { inaccessibleKeys.insert(bookmark) }
    }

    func markStale(_ bookmark: Data) {
        staleKeys.insert(bookmark)
    }

    func markInaccessible(_ bookmark: Data) {
        inaccessibleKeys.insert(bookmark)
    }

    func makeBookmark(for url: URL) throws -> Data {
        let data = Data("bookmark:\(url.path)".utf8)
        registry[data] = url
        staleKeys.remove(data)
        inaccessibleKeys.remove(data)
        return data
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if inaccessibleKeys.contains(data) {
            throw AuthoritativeDirectoryError.bookmarkInvalid("权限已撤销或目录不可用")
        }
        guard let url = registry[data] else {
            throw AuthoritativeDirectoryError.bookmarkInvalid("书签无法解析")
        }
        return (url, staleKeys.contains(data))
    }
}

// MARK: - Live implementations

@MainActor
final class UserDefaultsBookmarkStore: BookmarkDataStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "authoritative.directory.bookmark") {
        self.defaults = defaults
        self.key = key
    }

    func save(_ data: Data) throws {
        defaults.set(data, forKey: key)
    }

    func load() throws -> Data? {
        defaults.data(forKey: key)
    }

    func clear() throws {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
final class SystemSecurityScopedBookmarking: SecurityScopedBookmarking {
    func makeBookmark(for url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

// MARK: - Directory access service

@MainActor
final class BookmarkAuthoritativeDirectoryAccess: AuthoritativeDirectoryAccessing {
    private let bookmarkStore: any BookmarkDataStoring
    private let bookmarking: any SecurityScopedBookmarking
    private var activeScopedURL: URL?

    init(
        bookmarkStore: any BookmarkDataStoring,
        bookmarking: any SecurityScopedBookmarking
    ) {
        self.bookmarkStore = bookmarkStore
        self.bookmarking = bookmarking
    }

    func currentState() async -> AuthoritativeDirectoryState {
        do {
            guard let data = try bookmarkStore.load() else {
                return .unset
            }
            let resolved = try bookmarking.resolveBookmark(data)
            if resolved.isStale {
                return .needsReauthorization("持久书签已过期")
            }
            let url = resolved.url
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return .needsReauthorization("目录不存在或不是文件夹")
            }
            return .ready(makeInfo(for: url, accessible: true))
        } catch {
            return .needsReauthorization(error.localizedDescription)
        }
    }

    func selectDirectory(_ url: URL) async throws -> AuthoritativeDirectoryInfo {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AuthoritativeDirectoryError.notADirectory
        }

        let bookmark = try bookmarking.makeBookmark(for: url)
        try bookmarkStore.save(bookmark)
        // New directory becomes the sole source — previous bookmark is overwritten, no mirror.
        return makeInfo(for: url, accessible: true)
    }

    func authorizedDirectory() async throws -> URL {
        guard let data = try bookmarkStore.load() else {
            throw AuthoritativeDirectoryError.notSelected
        }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarking.resolveBookmark(data)
        } catch {
            throw AuthoritativeDirectoryError.bookmarkInvalid(error.localizedDescription)
        }
        if resolved.isStale {
            throw AuthoritativeDirectoryError.bookmarkInvalid("持久书签已过期")
        }

        // Keep scope open for subsequent writes in this session.
        if activeScopedURL?.path != resolved.url.path {
            activeScopedURL?.stopAccessingSecurityScopedResource()
            activeScopedURL = resolved.url
            guard resolved.url.startAccessingSecurityScopedResource() else {
                // For non-security-scoped paths (tests / already accessible), still allow if readable.
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue
                {
                    return resolved.url
                }
                throw AuthoritativeDirectoryError.accessDenied
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AuthoritativeDirectoryError.bookmarkInvalid("目录不可用")
        }
        return resolved.url
    }

    private func makeInfo(for url: URL, accessible: Bool) -> AuthoritativeDirectoryInfo {
        AuthoritativeDirectoryInfo(
            displayName: url.lastPathComponent,
            pathDescription: url.path,
            isAccessible: accessible
        )
    }
}
