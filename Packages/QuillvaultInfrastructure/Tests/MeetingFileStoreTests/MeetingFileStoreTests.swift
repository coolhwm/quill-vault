import Domain
import Foundation
import Testing

@testable import MeetingFileStore

@Suite("Meeting file store")
struct MeetingFileStoreTests {
  @Test("Recording without an authorized directory creates no meeting assets")
  func recordingRequiresAuthorizedDirectory() async {
    let bookmarks = InMemoryBookmarkStore()
    let store = MeetingFileStore(
      dependencies: .testing(bookmarkStore: bookmarks)
    )

    await #expect(throws: RecordingError.authoritativeDirectoryUnavailable) {
      _ = try await store.reserveRecording(for: .fixture())
    }
    #expect(await bookmarks.savedBookmark == nil)
  }

  @Test("Persists a selected directory and restores it after a cold start")
  func selectedDirectoryColdStart() async throws {
    let root = try TemporaryDirectory()
    let bookmarks = InMemoryBookmarkStore()
    let scopes = ScopeAccessSpy()
    let dependencies = MeetingFileStoreDependencies.testing(
      authorizedDirectory: root.url.appending(path: "default"),
      bookmarkStore: bookmarks,
      scopeAccess: scopes
    )
    let firstStore = MeetingFileStore(dependencies: dependencies)

    let selected = try await firstStore.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    let restored = try await MeetingFileStore(dependencies: dependencies)
      .restoreSelectedDirectory()

    #expect(selected == restored)
    #expect(await bookmarks.savedBookmark != nil)
  }

  @Test("Reauthorizing the same directory preserves its stable UUID identity")
  func sameDirectoryReauthorizationPreservesIdentity() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(bookmarkStore: InMemoryBookmarkStore())
    )

    let first = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    let second = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )

    #expect(first.id == second.id)
    #expect(UUID(uuidString: first.id.rawValue) != nil)
  }

  #if os(macOS)
    @Test("Foundation security-scoped bookmarks round-trip a real directory")
    func foundationBookmarkRoundTrip() throws {
      let root = try TemporaryDirectory()
      let codec = FoundationDirectoryBookmarkCodec()

      let bookmark = try codec.create(for: root.url)
      let restored = try codec.resolve(bookmark)

      #expect(
        restored.url.standardizedFileURL
          == root.url.standardizedFileURL
      )
      #expect(!restored.isStale)
    }
  #endif

  @Test("Starts and stops security-scoped access exactly once around a selected scan")
  func balancesSecurityScope() async throws {
    let fixture = try MeetingDirectoryFixture()
    let bookmarks = InMemoryBookmarkStore()
    let scopes = ScopeAccessSpy()
    let dependencies = MeetingFileStoreDependencies.testing(
      authorizedDirectory: fixture.root,
      bookmarkStore: bookmarks,
      scopeAccess: scopes
    )
    let store = MeetingFileStore(dependencies: dependencies)
    let selected = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: fixture.root.absoluteString)
    )
    let startsBeforeScan = await scopes.startCount
    let stopsBeforeScan = await scopes.stopCount

    _ = try await store.scan(selected)

    let startsAfterScan = await scopes.startCount
    let stopsAfterScan = await scopes.stopCount
    #expect(startsAfterScan == startsBeforeScan + 1)
    #expect(stopsAfterScan == stopsBeforeScan + 1)
    #expect(startsAfterScan == stopsAfterScan)
  }

  @Test("Cold transcription reacquires and balances selected-directory access")
  func balancesTranscriptionSecurityScope() async throws {
    let root = try TemporaryDirectory()
    let meetingID = MeetingID(rawValue: UUID())
    let meetingDirectory = root.url.appending(
      path: "meeting-20240801-080000",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: meetingDirectory,
      withIntermediateDirectories: true
    )
    let recordingURL = meetingDirectory.appending(path: "recording.m4a")
    #expect(
      FileManager.default.createFile(
        atPath: recordingURL.path,
        contents: Data([1])
      )
    )
    let manifest = MeetingManifest(
      meetingID: meetingID.rawValue,
      createdAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
    try JSONEncoder().encode(manifest).write(
      to: meetingDirectory.appending(path: "meeting.json")
    )
    let scopes = ScopeAccessSpy()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        bookmarkStore: InMemoryBookmarkStore(),
        scopeAccess: scopes
      )
    )
    _ = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    let startsBefore = await scopes.startCount
    let stopsBefore = await scopes.stopCount

    let resolved = try await store.beginTranscriptionAccess(
      meetingID: meetingID,
      recordingURL: URL(fileURLWithPath: "/previous-location")
        .appending(
          path: "meeting-20240801-080000",
          directoryHint: .isDirectory
        )
        .appending(path: "recording.m4a")
    )
    await store.endTranscriptionAccess(meetingID: meetingID)

    #expect(resolved.standardizedFileURL == recordingURL.standardizedFileURL)
    #expect(await scopes.startCount == startsBefore + 2)
    #expect(await scopes.stopCount == stopsBefore + 2)
  }

  @Test("Transcription cannot escape the authoritative directory")
  func transcriptionRejectsOutsidePath() async throws {
    let root = try TemporaryDirectory()
    let outside = try TemporaryDirectory()
    let recordingURL = outside.url.appending(path: "recording.m4a")
    #expect(
      FileManager.default.createFile(
        atPath: recordingURL.path,
        contents: Data([1])
      )
    )
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )

    await #expect(throws: TranscriptError.recordingUnavailable) {
      try await store.beginTranscriptionAccess(
        meetingID: MeetingID(rawValue: UUID()),
        recordingURL: recordingURL
      )
    }
  }

  @Test("A stale selected bookmark fails without creating a fallback directory")
  func staleBookmarkDoesNotFallBack() async {
    let bookmarks = InMemoryBookmarkStore(
      savedBookmark: Data("stale".utf8)
    )
    let dependencies = MeetingFileStoreDependencies.testing(
      bookmarkStore: bookmarks,
      bookmarkCodec: StaleBookmarkCodec()
    )
    let store = MeetingFileStore(dependencies: dependencies)

    await #expect(throws: DirectoryAccessError.bookmarkStale) {
      _ = try await store.restoreSelectedDirectory()
    }
  }

  @Test("Coordinated scans preserve stable IDs, ignore candidates, and never modify assets")
  func coordinatedReadOnlyScan() async throws {
    let fixture = try MeetingDirectoryFixture()
    let before = try fixture.snapshot()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try #require(await store.restoreSelectedDirectory())

    let firstScan = try await store.scan(directory)
    let secondScan = try await store.scan(directory)

    #expect(firstScan.meetings.map(\.id) == [fixture.meetingID])
    #expect(secondScan.meetings.map(\.id) == [fixture.meetingID])
    #expect(firstScan.fingerprints.count == 2)
    #expect(firstScan.diagnostics.map(\.code).contains(.candidateIgnored))
    #expect(try fixture.snapshot() == before)
  }

  @Test("Rebuilds card title, duration, and model from authoritative Markdown")
  func rebuildsMeetingCardMetadata() async throws {
    let root = try TemporaryDirectory()
    let meeting = root.url.appending(
      path: "meeting-20260730-120000",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: meeting,
      withIntermediateDirectories: true
    )
    let manifest = MeetingManifest(
      meetingID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try JSONEncoder().encode(manifest).write(
      to: meeting.appending(path: "meeting.json")
    )
    try Data(
      """
      audioDurationSeconds: 125.5
      - [000.0–125.5] Text
      """.utf8
    ).write(to: meeting.appending(path: "transcript.md"))
    try Data(
      """
      ---
      title: "Weekly review"
      model: test-model
      ---

      # Weekly review
      """.utf8
    ).write(to: meeting.appending(path: "minutes.md"))
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let directory = try #require(await store.restoreSelectedDirectory())

    let entry = try #require(
      await store.scan(directory).meetings.first
    )

    #expect(entry.title == "Weekly review")
    #expect(entry.durationSeconds == 125.5)
    #expect(entry.modelName == "test-model")
  }

  @Test("Scans 2,000 transcript-backed recordings within the metadata budget")
  func largeMetadataScan() async throws {
    let root = try TemporaryDirectory()
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let transcript = Data(
      """
      audioDurationSeconds: 60
      - [000.0–060.0] Text
      """.utf8
    )
    for index in 0..<2_000 {
      let meeting = root.url.appending(
        path: String(format: "meeting-20260730-%06d", index),
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: meeting,
        withIntermediateDirectories: true
      )
      try JSONEncoder().encode(
        MeetingManifest(meetingID: UUID(), createdAt: createdAt)
      ).write(to: meeting.appending(path: "meeting.json"))
      try transcript.write(to: meeting.appending(path: "transcript.md"))
      try Data([0]).write(to: meeting.appending(path: "recording.m4a"))
    }
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let directory = try #require(await store.restoreSelectedDirectory())
    let clock = ContinuousClock()
    let startedAt = clock.now

    let scan = try await store.scan(directory)

    #expect(scan.meetings.count == 2_000)
    #expect(startedAt.duration(to: clock.now) < .seconds(5))
    #expect(scan.meetings.allSatisfy { $0.durationSeconds == 60 })
  }

  @Test("An iCloud recording placeholder keeps the meeting discoverable")
  func iCloudRecordingPlaceholderKeepsMeetingDiscoverable() async throws {
    let fixture = try MeetingDirectoryFixture()
    let status = UbiquitousStatusStub(unavailableFileName: "recording.m4a")
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        ubiquitousStatus: status
      )
    )
    let directory = try #require(await store.restoreSelectedDirectory())

    let scan = try await store.scan(directory)

    #expect(scan.meetings.count == 1)
    #expect(scan.meetings[0].assets.contains(.recording))
    #expect(
      scan.fingerprints.contains(where: { $0.asset == .recording }) == false
    )
  }

  @Test("An undownloaded authoritative root blocks new writes")
  func undownloadedRootBlocksRecording() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        ubiquitousStatus: UbiquitousStatusStub(
          unavailableFileName: root.url.lastPathComponent
        )
      )
    )

    await #expect(throws: RecordingError.authoritativeDirectoryUnavailable) {
      _ = try await store.reserveRecording(for: .fixture())
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        .isEmpty
    )
  }

  @Test("An undownloaded meeting manifest requests an iCloud download")
  func iCloudManifestPlaceholderStopsScan() async throws {
    let fixture = try MeetingDirectoryFixture()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: fixture.root,
        ubiquitousStatus: UbiquitousStatusStub(
          unavailableFileName: "meeting.json"
        )
      )
    )
    let directory = try #require(await store.restoreSelectedDirectory())

    await #expect(throws: DirectoryAccessError.itemNotDownloaded) {
      _ = try await store.scan(directory)
    }
  }

  @Test("Root read permission errors preserve the reauthorization recovery")
  func rootPermissionErrorMapping() {
    let scanner = MeetingDirectoryScanner(
      ubiquitousStatus: AlwaysDownloadedItemStatusChecker()
    )

    #expect(
      scanner.rootReadError(for: CocoaError(.fileReadNoPermission))
        == .permissionDenied
    )
  }

  @Test("A moved selected directory reports reauthorization and balances scope")
  func movedSelectedDirectory() async throws {
    let root = try TemporaryDirectory()
    let scopes = ScopeAccessSpy()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        scopeAccess: scopes
      )
    )
    let selected = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    try FileManager.default.removeItem(at: root.url)

    await #expect(throws: DirectoryAccessError.directoryMoved) {
      _ = try await store.scan(selected)
    }
    #expect(await scopes.startCount == 2)
    #expect(await scopes.stopCount == 2)
  }

  @Test("Permission loss stops a scan before reading the directory")
  func permissionLossStopsScan() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        scopeAccess: ScopeAccessSpy(allowsAccess: false)
      )
    )
    await #expect(throws: DirectoryAccessError.permissionDenied) {
      _ = try await store.restoreSelectedDirectory()
    }
  }

  @Test("Selecting another directory changes authority without moving existing files")
  func selectingAnotherDirectoryDoesNotMigrateFiles() async throws {
    let first = try TemporaryDirectory()
    let second = try TemporaryDirectory()
    let sentinel = first.url.appending(path: "existing-meeting.md")
    try Data("preserve".utf8).write(to: sentinel)
    let bookmarks = InMemoryBookmarkStore()
    let store = MeetingFileStore(
      dependencies: .testing(bookmarkStore: bookmarks)
    )

    _ = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: first.url.absoluteString)
    )
    let selected = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: second.url.absoluteString)
    )
    let restored = try await store.restoreSelectedDirectory()

    #expect(restored == selected)
    #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: second.url.path)
        .isEmpty
    )
  }

  @Test("An active recording prevents switching its authoritative directory")
  func activeRecordingPreventsDirectorySwitch() async throws {
    let first = try TemporaryDirectory()
    let second = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: first.url)
    )
    let reservation = try await store.reserveRecording(for: .fixture())

    await #expect(throws: DirectoryAccessError.coordinationFailed) {
      _ = try await store.authorizeSelectedDirectory(
        .init(opaqueReference: second.url.absoluteString)
      )
    }

    #expect(
      reservation.directoryURL.deletingLastPathComponent()
        .standardizedFileURL == first.url.standardizedFileURL
    )
    await store.cancelRecording(meetingID: reservation.meetingID)
  }

  @Test("A cancelled scan exits before producing a replacement snapshot")
  func scanCancellation() async throws {
    let fixture = try MeetingDirectoryFixture()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: fixture.root)
    )
    let directory = try #require(await store.restoreSelectedDirectory())
    let task = Task {
      try await store.scan(directory)
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  @Test("Low storage rejects recording before creating a meeting directory")
  func lowStorageCreatesNoRecordingDirectory() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        minimumRecordingCapacityBytes: 1_000,
        availableCapacity: { _ in 999 }
      )
    )
    let session = RecordingSession.fixture()

    await #expect(throws: RecordingError.insufficientStorage) {
      _ = try await store.reserveRecording(for: session)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.url.path).isEmpty
    )
  }

  @Test("Publishing a recording creates a readable identity manifest without replacing files")
  func publishesRecordingIdentity() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let session = RecordingSession.fixture()
    let reservation = try await store.reserveRecording(for: session)
    #expect(
      reservation.directoryURL.lastPathComponent.range(
        of: #"^meeting-[0-9]{8}-[0-9]{6}$"#,
        options: .regularExpression
      ) != nil
    )
    try Data("audio-header".utf8).write(to: reservation.recordingURL)

    try await store.publishRecordingStart(
      reservation,
      startedAt: session.startedAt
    )
    #expect(
      FileManager.default.fileExists(
        atPath: reservation.directoryURL
          .appending(path: ".recording.json").path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: reservation.directoryURL
          .appending(path: "meeting.json").path
      )
    )
    try await store.finishRecording(meetingID: session.meetingID)

    let manifestData = try Data(
      contentsOf: reservation.directoryURL.appending(path: "meeting.json")
    )
    let manifest = try JSONDecoder().decode(
      MeetingManifest.self,
      from: manifestData
    )
    #expect(manifest.meetingID == session.meetingID.rawValue)
    #expect(
      try Data(contentsOf: reservation.recordingURL)
        == Data("audio-header".utf8)
    )
  }

  @Test("Recording interruptions survive without polluting identity manifest")
  func persistsRecordingInterruptions() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let session = RecordingSession.fixture()
    let reservation = try await store.reserveRecording(for: session)
    try Data("audio-header".utf8).write(to: reservation.recordingURL)
    try await store.publishRecordingStart(
      reservation,
      startedAt: session.startedAt
    )
    let events: [RecordingCaptureEvent] = [
      .interruptionBegan(
        at: session.startedAt.addingTimeInterval(20),
        reason: .systemInterruption
      ),
      .interruptionEnded(
        at: session.startedAt.addingTimeInterval(27),
        didResume: true
      ),
    ]

    for event in events {
      try await store.recordCaptureEvent(
        event,
        meetingID: session.meetingID
      )
    }
    #expect(
      try await store.recordingCaptureEvents(
        meetingID: session.meetingID
      ) == events
    )
    try await store.finishRecording(meetingID: session.meetingID)

    let data = try Data(
      contentsOf: reservation.directoryURL.appending(path: "meeting.json")
    )
    let identity = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(Set(identity.keys) == ["schemaVersion", "meetingID", "createdAt"])

    let eventData = try Data(
      contentsOf: reservation.directoryURL.appending(
        path: ".recording-events.json"
      )
    )
    let eventLog = try JSONDecoder().decode(
      RecordingCaptureEventLog.self,
      from: eventData
    )
    #expect(eventLog.meetingID == session.meetingID.rawValue)
    #expect(eventLog.events == events)
  }

  @Test("A continuation replaces recording only after its candidate exists")
  func commitsRecordingContinuationAtomically() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let session = RecordingSession.fixture()
    let original = try await store.reserveRecording(for: session)
    let originalBytes = Data("original-audio".utf8)
    try originalBytes.write(to: original.recordingURL)
    try await store.publishRecordingStart(
      original,
      startedAt: session.startedAt
    )
    let continuation = try await store.reserveRecordingContinuation(
      for: session
    )
    let mergedBytes = Data("validated-merged-audio".utf8)
    try Data("continuation-audio".utf8).write(
      to: continuation.continuationURL
    )

    await #expect(throws: RecordingError.recordingWriteFailed) {
      try await store.commitRecordingContinuation(continuation)
    }
    #expect(try Data(contentsOf: original.recordingURL) == originalBytes)

    try mergedBytes.write(to: continuation.candidateURL)
    try await store.commitRecordingContinuation(continuation)

    #expect(try Data(contentsOf: original.recordingURL) == mergedBytes)
    #expect(
      !FileManager.default.fileExists(
        atPath: continuation.continuationURL.path
      )
    )
  }

  @Test("A failed post-replace confirmation restores original audio")
  func continuationConfirmationFailureRollsBack() async throws {
    let root = try TemporaryDirectory()
    let digest = RecordingDigestFault()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        recordingDigest: digest.digest
      )
    )
    let session = RecordingSession.fixture()
    let original = try await store.reserveRecording(for: session)
    let originalBytes = Data("original-audio".utf8)
    try originalBytes.write(to: original.recordingURL)
    try await store.publishRecordingStart(
      original,
      startedAt: session.startedAt
    )
    let continuation = try await store.reserveRecordingContinuation(
      for: session
    )
    try Data("continuation-audio".utf8).write(
      to: continuation.continuationURL
    )
    try Data("candidate-audio".utf8).write(
      to: continuation.candidateURL
    )

    await #expect(throws: RecordingError.recordingWriteFailed) {
      try await store.commitRecordingContinuation(continuation)
    }

    #expect(try Data(contentsOf: original.recordingURL) == originalBytes)
    #expect(
      FileManager.default.fileExists(
        atPath: continuation.continuationURL.path
      )
    )
  }

  @Test(
    "Continuation commit faults never replace existing audio",
    arguments: [
      RecordingMutationFault.writeBefore,
      .writeDuring,
      .replace(afterSuccessfulMatches: 1),
    ]
  )
  fileprivate func continuationMutationFaultPreservesOriginal(
    fault: RecordingMutationFault
  ) async throws {
    let root = try TemporaryDirectory()
    let mutator = FaultInjectingRecordingFileMutator()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        fileMutator: mutator
      )
    )
    let session = RecordingSession.fixture()
    let original = try await store.reserveRecording(for: session)
    let originalBytes = Data("original-audio".utf8)
    try originalBytes.write(to: original.recordingURL)
    try await store.publishRecordingStart(
      original,
      startedAt: session.startedAt
    )
    let continuation = try await store.reserveRecordingContinuation(
      for: session
    )
    try Data("continuation-audio".utf8).write(
      to: continuation.continuationURL
    )
    try Data("candidate-audio".utf8).write(
      to: continuation.candidateURL
    )
    mutator.arm(fault)

    await #expect(throws: RecordingError.recordingWriteFailed) {
      try await store.commitRecordingContinuation(continuation)
    }

    #expect(try Data(contentsOf: original.recordingURL) == originalBytes)
    #expect(
      FileManager.default.fileExists(
        atPath: continuation.continuationURL.path
      )
    )
  }

  @Test("A continuation reservation survives process recreation")
  func recoversRecordingContinuationReservation() async throws {
    let root = try TemporaryDirectory()
    let dependencies = MeetingFileStoreDependencies.testing(
      authorizedDirectory: root.url
    )
    let session = RecordingSession.fixture()
    let firstStore = MeetingFileStore(dependencies: dependencies)
    let original = try await firstStore.reserveRecording(for: session)
    try Data("original-audio".utf8).write(to: original.recordingURL)
    try await firstStore.publishRecordingStart(
      original,
      startedAt: session.startedAt
    )
    let continuation = try await firstStore.reserveRecordingContinuation(
      for: session
    )
    try Data("continuation-audio".utf8).write(
      to: continuation.continuationURL
    )

    let recoveredStore = MeetingFileStore(dependencies: dependencies)
    _ = try #require(
      try await recoveredStore.recoverInterruptedRecording(for: session)
    )
    let recovered =
      try await recoveredStore
      .recoverRecordingContinuation(for: session)

    let recoveredReservation = try #require(recovered)
    #expect(recoveredReservation.meetingID == continuation.meetingID)
    #expect(
      recoveredReservation.originalRecordingURL.resolvingSymlinksInPath()
        == continuation.originalRecordingURL.resolvingSymlinksInPath()
    )
    #expect(
      recoveredReservation.continuationURL.resolvingSymlinksInPath()
        == continuation.continuationURL.resolvingSymlinksInPath()
    )
    #expect(
      recoveredReservation.candidateURL.lastPathComponent
        == continuation.candidateURL.lastPathComponent
    )
    #expect(
      recoveredReservation.candidateURL.deletingLastPathComponent()
        .resolvingSymlinksInPath()
        == continuation.candidateURL.deletingLastPathComponent()
        .resolvingSymlinksInPath()
    )
    #expect(try Data(contentsOf: original.recordingURL) == Data("original-audio".utf8))
  }

  @Test("A tampered continuation transaction cannot target original audio")
  func rejectsContinuationManifestPathCollision() throws {
    let meetingID = UUID()
    let data = Data(
      """
      {
        "schemaVersion": 1,
        "meetingID": "\(meetingID.uuidString)",
        "continuationFileName": "recording.m4a",
        "candidateFileName": ".recording-merged-safe.m4a",
        "state": "recording"
      }
      """.utf8
    )
    let manifest = try JSONDecoder().decode(
      RecordingContinuationManifest.self,
      from: data
    )
    let directory = URL(fileURLWithPath: "/authorized/meeting")

    #expect(throws: RecordingError.recordingWriteFailed) {
      _ = try manifest.reservation(
        directoryURL: directory,
        originalRecordingURL: directory.appending(path: "recording.m4a")
      )
    }
  }

  @Test("Cold start reopens an interrupted recording without replacing its audio")
  func reopensInterruptedRecording() async throws {
    let root = try TemporaryDirectory()
    let dependencies = MeetingFileStoreDependencies.testing(
      authorizedDirectory: root.url
    )
    let firstStore = MeetingFileStore(dependencies: dependencies)
    let session = RecordingSession.fixture()
    let original = try await firstStore.reserveRecording(for: session)
    let audio = Data("interrupted-audio".utf8)
    try audio.write(to: original.recordingURL)
    let terminationBoundary = session.startedAt.addingTimeInterval(18)
    try FileManager.default.setAttributes(
      [.modificationDate: terminationBoundary],
      ofItemAtPath: original.recordingURL.path
    )
    try await firstStore.publishRecordingStart(
      original,
      startedAt: session.startedAt
    )
    #expect(
      try await firstStore.recordingCaptureEvents(
        meetingID: session.meetingID
      ).isEmpty
    )

    let recoveredStore = MeetingFileStore(dependencies: dependencies)
    let recovered =
      try await recoveredStore
      .recoverInterruptedRecording(for: session)

    let reopened = try #require(recovered)
    #expect(reopened.meetingID == original.meetingID)
    #expect(reopened.createdAt == original.createdAt)
    #expect(
      reopened.directoryURL.standardizedFileURL
        == original.directoryURL.standardizedFileURL
    )
    #expect(
      reopened.recordingURL.standardizedFileURL
        == original.recordingURL.standardizedFileURL
    )
    #expect(try Data(contentsOf: reopened.recordingURL) == audio)
    #expect(
      try await recoveredStore.recordingCaptureEvents(
        meetingID: session.meetingID
      ) == [
        .interruptionBegan(
          at: terminationBoundary,
          reason: .processTermination
        )
      ]
    )
  }

  @Test("A tampered pending manifest is never published as a meeting")
  func tamperedPendingManifestIsRejected() async throws {
    let root = try TemporaryDirectory()
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let session = RecordingSession.fixture()
    let reservation = try await store.reserveRecording(for: session)
    let audio = Data("preserve-audio".utf8)
    try audio.write(to: reservation.recordingURL)
    try await store.publishRecordingStart(
      reservation,
      startedAt: session.startedAt
    )
    let tamperedManifest = """
      {
        "schemaVersion": 1,
        "meetingID": "\(session.meetingID.rawValue.uuidString)",
        "createdAt": "not-a-date"
      }
      """
    try Data(tamperedManifest.utf8).write(
      to: reservation.directoryURL.appending(path: ".recording.json")
    )

    await #expect(throws: (any Error).self) {
      try await store.finishRecording(meetingID: session.meetingID)
    }

    #expect(
      !FileManager.default.fileExists(
        atPath: reservation.directoryURL
          .appending(path: "meeting.json").path
      )
    )
    #expect(try Data(contentsOf: reservation.recordingURL) == audio)
  }

  @Test("A same-second meeting uses a suffix without replacing existing files")
  func existingMeetingIsProtected() async throws {
    let root = try TemporaryDirectory()
    let session = RecordingSession.fixture()
    let firstStore = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let firstSession = RecordingSession(
      meetingID: MeetingID(rawValue: UUID()),
      startedAt: session.startedAt
    )
    let first = try await firstStore.reserveRecording(for: firstSession)
    let existing = first.directoryURL
    let sentinel = existing.appending(path: "sentinel")
    try Data("keep".utf8).write(to: sentinel)
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )

    let second = try await store.reserveRecording(for: session)

    #expect(second.directoryURL.lastPathComponent.hasSuffix("-2"))
    #expect(second.directoryURL != existing)
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  @Test("Cancellation removes only the reservation created by that recording")
  func cancellationRemovesOwnedReservation() async throws {
    let root = try TemporaryDirectory()
    let unrelated = root.url.appending(
      path: "unrelated",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: unrelated,
      withIntermediateDirectories: false
    )
    let store = MeetingFileStore(
      dependencies: .testing(authorizedDirectory: root.url)
    )
    let session = RecordingSession.fixture()
    let reservation = try await store.reserveRecording(for: session)

    await store.cancelRecording(meetingID: session.meetingID)

    #expect(!FileManager.default.fileExists(atPath: reservation.directoryURL.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test("Abandoning invalid audio preserves recovery files and releases scope")
  func abandonmentPreservesRecoveryAndReleasesScope() async throws {
    let root = try TemporaryDirectory()
    let scopes = ScopeAccessSpy()
    let store = MeetingFileStore(
      dependencies: .testing(
        authorizedDirectory: root.url,
        scopeAccess: scopes
      )
    )
    _ = try await store.authorizeSelectedDirectory(
      .init(opaqueReference: root.url.absoluteString)
    )
    let session = RecordingSession.fixture()
    let reservation = try await store.reserveRecording(for: session)
    try Data("recoverable".utf8).write(to: reservation.recordingURL)
    try await store.publishRecordingStart(
      reservation,
      startedAt: session.startedAt
    )

    await store.abandonRecording(meetingID: session.meetingID)

    #expect(
      FileManager.default.fileExists(atPath: reservation.recordingURL.path)
    )
    #expect(
      FileManager.default.fileExists(
        atPath: reservation.directoryURL
          .appending(path: ".recording.json").path
      )
    )
    #expect(await scopes.startCount == 3)
    #expect(await scopes.stopCount == 3)
  }
}

private struct MeetingDirectoryFixture {
  private let temporary: TemporaryDirectory
  let root: URL
  let meetingID = MeetingID(
    rawValue: UUID(uuidString: "51529D31-2205-4299-BECE-FA489FF9FA22")!
  )

  init() throws {
    let temporary = try TemporaryDirectory()
    self.temporary = temporary
    root = temporary.url

    let meeting = root.appending(path: "meeting-20260730-120000", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    let manifest = """
      {"schemaVersion":1,"meetingID":"\(meetingID.rawValue.uuidString)","createdAt":"2026-07-30T04:00:00Z"}
      """
    try Data(manifest.utf8).write(to: meeting.appending(path: "meeting.json"))
    try Data("audio".utf8).write(to: meeting.appending(path: "recording.m4a"))
    try Data("# Transcript".utf8).write(to: meeting.appending(path: "transcript.md"))

    let candidate = root.appending(
      path: "meeting-20260730-120000.candidate",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: candidate.appending(path: "minutes.md"))
  }

  func snapshot() throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil
    )
    var result: [String: Data] = [:]
    while let fileURL = enumerator?.nextObject() as? URL {
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
      if !isDirectory.boolValue {
        let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
        result[relative] = try Data(contentsOf: fileURL)
      }
    }
    return result
  }
}

private final class RecordingDigestFault: @unchecked Sendable {
  private let lock = NSLock()
  private var originalReadCount = 0

  func digest(_ url: URL) throws -> String {
    if url.lastPathComponent == "recording.m4a" {
      let shouldFailConfirmation = lock.withLock {
        originalReadCount += 1
        return originalReadCount == 2
      }
      if shouldFailConfirmation {
        return "forced-confirmation-mismatch"
      }
    }
    return try RecordingContinuationManifest.digest(of: url)
  }
}

private enum RecordingMutationFault: Sendable {
  case writeBefore
  case writeDuring
  case replace(afterSuccessfulMatches: Int)
}

private struct InjectedRecordingMutationError: Error {}

private final class FaultInjectingRecordingFileMutator:
  RecordingFileMutating,
  @unchecked Sendable
{
  private enum Action {
    case failBefore
    case writePartially
  }

  private let lock = NSLock()
  private let base = FoundationRecordingFileMutator()
  private var fault: RecordingMutationFault?

  func arm(_ fault: RecordingMutationFault) {
    lock.withLock {
      self.fault = fault
    }
  }

  func writeSynced(_ data: Data, to url: URL) throws {
    let action: Action? = lock.withLock {
      switch fault {
      case .writeBefore:
        fault = nil
        return .failBefore
      case .writeDuring:
        fault = nil
        return .writePartially
      case .replace, nil:
        return nil
      }
    }
    switch action {
    case .failBefore:
      throw InjectedRecordingMutationError()
    case .writePartially:
      let prefixCount = max(1, data.count / 2)
      try base.writeSynced(Data(data.prefix(prefixCount)), to: url)
      throw InjectedRecordingMutationError()
    case nil:
      try base.writeSynced(data, to: url)
    }
  }

  func replace(
    itemAt destinationURL: URL,
    with sourceURL: URL,
    backupItemName: String?,
    keepBackup: Bool
  ) throws {
    let shouldFail: Bool = lock.withLock {
      guard case .replace(let remaining)? = fault else {
        return false
      }
      if remaining > 0 {
        fault = .replace(afterSuccessfulMatches: remaining - 1)
        return false
      }
      fault = nil
      return true
    }
    if shouldFail {
      throw InjectedRecordingMutationError()
    }
    try base.replace(
      itemAt: destinationURL,
      with: sourceURL,
      backupItemName: backupItemName,
      keepBackup: keepBackup
    )
  }

  func move(itemAt sourceURL: URL, to destinationURL: URL) throws {
    try base.move(itemAt: sourceURL, to: destinationURL)
  }

  func removeItem(at url: URL) throws {
    try base.removeItem(at: url)
  }
}

private final class TemporaryDirectory: @unchecked Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "quillvault-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

private actor InMemoryBookmarkStore: DirectoryBookmarkStoring {
  private(set) var savedBookmark: Data?

  init(savedBookmark: Data? = nil) {
    self.savedBookmark = savedBookmark
  }

  func load() async -> Data? {
    savedBookmark
  }

  func save(_ data: Data) async throws {
    savedBookmark = data
  }
}

private actor ScopeAccessSpy: SecurityScopedResourceAccessing {
  private let allowsAccess: Bool
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(allowsAccess: Bool = true) {
    self.allowsAccess = allowsAccess
  }

  func startAccessing(_ url: URL) async -> Bool {
    startCount += 1
    return allowsAccess
  }

  func stopAccessing(_ url: URL) async {
    stopCount += 1
  }
}

private struct StaleBookmarkCodec: DirectoryBookmarkCoding {
  func create(for url: URL) throws -> Data {
    Data()
  }

  func resolve(_ data: Data) throws -> ResolvedDirectoryBookmark {
    .init(url: URL(fileURLWithPath: "/stale"), isStale: true)
  }
}

private struct UbiquitousStatusStub: UbiquitousItemStatusChecking {
  let unavailableFileName: String

  func isDownloaded(_ url: URL) throws -> Bool {
    url.lastPathComponent != unavailableFileName
  }
}

extension RecordingSession {
  fileprivate static func fixture() -> Self {
    .init(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "5F6FA632-D2A8-4A4E-B3D9-162F2BEF4E2B")!
      ),
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}
