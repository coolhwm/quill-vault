import XCTest
@testable import QuillvaultDemo

@MainActor
final class AuthoritativeDirectoryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillvaultDirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFirstSelectionPersistsAndExposesIdentifiableDirectory() async throws {
        let bookmarking = ControllableBookmarking()
        let store = InMemoryBookmarkStore()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
            bookmarking: bookmarking
        )
        let workflow = makeWorkflow(access: access)

        XCTAssertEqual(workflow.directoryState, .unset)

        let folder = try makeFolder("ObsidianVault")
        await workflow.applySelectedDirectory(folder)

        guard case let .ready(info) = workflow.directoryState else {
            return XCTFail("Expected ready directory")
        }
        XCTAssertEqual(info.displayName, "ObsidianVault")
        XCTAssertTrue(info.pathDescription.contains("ObsidianVault"))
        XCTAssertTrue(info.isAccessible)
        XCTAssertNotNil(try store.load())
        let authorized = try await access.authorizedDirectory()
        XCTAssertEqual(authorized.lastPathComponent, "ObsidianVault")
    }

    func testRestartReloadsBookmarkAndRestoresSameDirectory() async throws {
        let bookmarking = ControllableBookmarking()
        let store = InMemoryBookmarkStore()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
            bookmarking: bookmarking
        )
        let first = makeWorkflow(access: access)
        let folder = try makeFolder("iCloudDrive-Quillvault")
        await first.applySelectedDirectory(folder)
        let firstAuthorized = try await access.authorizedDirectory()
        XCTAssertEqual(firstAuthorized.path, folder.path)

        // Simulate relaunch with the same persisted store + bookmark registry.
        let restoredAccess = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
            bookmarking: bookmarking
        )
        let reloaded = makeWorkflow(access: restoredAccess)
        await reloaded.reloadAuthoritativeDirectory()

        guard case let .ready(info) = reloaded.directoryState else {
            return XCTFail("Expected restored ready directory")
        }
        XCTAssertEqual(info.displayName, "iCloudDrive-Quillvault")
        let restored = try await restoredAccess.authorizedDirectory()
        XCTAssertEqual(restored.path, folder.path)
    }

    func testReselectReplacesSoleSourceWithoutMirror() async throws {
        let bookmarking = ControllableBookmarking()
        let store = InMemoryBookmarkStore()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
            bookmarking: bookmarking
        )
        let workflow = makeWorkflow(access: access)

        let first = try makeFolder("FirstVault")
        let second = try makeFolder("SecondVault")
        await workflow.applySelectedDirectory(first)
        let firstBookmark = try XCTUnwrap(try store.load())

        await workflow.applySelectedDirectory(second)
        let secondBookmark = try XCTUnwrap(try store.load())

        XCTAssertNotEqual(firstBookmark, secondBookmark)
        let authorized = try await access.authorizedDirectory()
        XCTAssertEqual(authorized.lastPathComponent, "SecondVault")
        guard case let .ready(info) = workflow.directoryState else {
            return XCTFail("Expected second directory")
        }
        XCTAssertEqual(info.displayName, "SecondVault")
        // Only one bookmark blob is retained — no mirror path created.
        XCTAssertEqual(try store.load(), secondBookmark)
    }

    func testInvalidAuthorizationBlocksWritesAndEntersRecoveryState() async throws {
        let bookmarking = ControllableBookmarking()
        let store = InMemoryBookmarkStore()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
            bookmarking: bookmarking
        )
        let workflow = makeWorkflow(access: access, seedAPIKey: "sk-test")
        let folder = try makeFolder("RevokedVault")
        await workflow.applySelectedDirectory(folder)

        let bookmark = try XCTUnwrap(try store.load())
        bookmarking.markInaccessible(bookmark)
        await workflow.reloadAuthoritativeDirectory()

        guard case let .needsReauthorization(message) = workflow.directoryState else {
            return XCTFail("Expected recovery state")
        }
        XCTAssertTrue(message.contains("权限") || message.contains("失效") || message.contains("撤销"))
        XCTAssertFalse(workflow.directoryState.isWritable)

        await workflow.startFaceToFaceSession()
        guard case let .failed(errorMessage) = workflow.state else {
            return XCTFail("Expected session blocked without sandbox fallback")
        }
        XCTAssertTrue(
            errorMessage.contains("权威目录")
                || errorMessage.contains("授权")
                || errorMessage.contains("书签")
                || errorMessage.contains("选择")
        )
        XCTAssertFalse(errorMessage.contains("沙盒隐藏副本") && errorMessage.contains("已写入"))
    }

    func testStaleBookmarkRequiresReauthorization() async throws {
        let bookmarking = ControllableBookmarking()
        let store = InMemoryBookmarkStore()
        let access = BookmarkAuthoritativeDirectoryAccess(
            bookmarkStore: store,
            bookmarking: bookmarking
        )
        let workflow = makeWorkflow(access: access)
        let folder = try makeFolder("StaleVault")
        await workflow.applySelectedDirectory(folder)
        let bookmark = try XCTUnwrap(try store.load())
        bookmarking.markStale(bookmark)
        await workflow.reloadAuthoritativeDirectory()

        guard case .needsReauthorization = workflow.directoryState else {
            return XCTFail("Expected stale bookmark recovery")
        }
        do {
            _ = try await access.authorizedDirectory()
            XCTFail("Expected stale bookmark to block authorizedDirectory")
        } catch {
            XCTAssertEqual(
                error as? AuthoritativeDirectoryError,
                .bookmarkInvalid("持久书签已过期")
            )
        }
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeWorkflow(
        access: BookmarkAuthoritativeDirectoryAccess,
        seedAPIKey: String? = "demo-seed-key"
    ) -> MeetingWorkflow {
        let keyStore = InMemoryAPIKeyStore(initial: seedAPIKey)
        return MeetingWorkflow(
            dependencies: MeetingWorkflowDependencies(
                audioRecorder: DemoAudioRecorder(),
                transcriber: DemoTranscriber(),
                minutesGenerator: DemoMinutesGenerator(shouldFail: false),
                credentialChecker: StoreBackedCredentialChecker(store: keyStore),
                directoryAccess: access,
                assetWriter: DemoAssetWriter(),
                mermaidGenerator: DeterministicMermaidGenerator(),
                mermaidRenderer: DemoMermaidRenderer(),
                apiKeyStore: keyStore,
                byokPreferences: InMemoryBYOKPreferences(),
                connectionTester: ControllableDemoConnectionTester()
            )
        )
    }
}
