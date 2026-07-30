import AVFAudio
import Domain
import Foundation

public actor MeetingFileStore:
  AuthoritativeDirectoryAccess, TranscriptionRecoverySource
{
  private struct PersistedDirectoryAuthorization: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let bookmark: Data

    init(id: UUID, bookmark: Data) {
      schemaVersion = 1
      self.id = id
      self.bookmark = bookmark
    }
  }

  struct ResolvedRoot: Sendable {
    let url: URL
    let directory: AuthoritativeDirectory
  }

  private struct ActiveRecordingReservation: Sendable {
    let reservation: RecordingFileReservation
    let securityScopedRoot: URL?
  }

  let dependencies: MeetingFileStoreDependencies
  private let coordinatedFiles: CoordinatedRecordingFileAccess
  private let captureEventStore: RecordingCaptureEventStore
  private let continuationTransaction: RecordingContinuationTransaction
  var resolvedRoots: [AuthoritativeDirectoryID: ResolvedRoot] = [:]
  private var recordingReservations: [MeetingID: ActiveRecordingReservation] = [:]
  private var continuationReservations: [MeetingID: RecordingContinuationReservation] = [:]
  private var transcriptionAccessMeetings = Set<MeetingID>()
  private var transcriptionScopedRoots: [MeetingID: URL] = [:]
  private var transcriptionRecordingURLs: [MeetingID: URL] = [:]
  var playbackScopedRoots: [MeetingAudioSourceID: URL] = [:]

  public init() {
    let dependencies = MeetingFileStoreDependencies.live()
    let coordinatedFiles = CoordinatedRecordingFileAccess(
      mutator: dependencies.fileMutator,
      digest: dependencies.recordingDigest
    )
    self.dependencies = dependencies
    self.coordinatedFiles = coordinatedFiles
    captureEventStore = RecordingCaptureEventStore(
      files: coordinatedFiles,
      makeUUID: dependencies.makeUUID
    )
    continuationTransaction = RecordingContinuationTransaction(
      files: coordinatedFiles,
      mutator: dependencies.fileMutator,
      makeUUID: dependencies.makeUUID
    )
  }

  init(dependencies: MeetingFileStoreDependencies) {
    let coordinatedFiles = CoordinatedRecordingFileAccess(
      mutator: dependencies.fileMutator,
      digest: dependencies.recordingDigest
    )
    self.dependencies = dependencies
    self.coordinatedFiles = coordinatedFiles
    captureEventStore = RecordingCaptureEventStore(
      files: coordinatedFiles,
      makeUUID: dependencies.makeUUID
    )
    continuationTransaction = RecordingContinuationTransaction(
      files: coordinatedFiles,
      mutator: dependencies.fileMutator,
      makeUUID: dependencies.makeUUID
    )
  }

  public func restoreSelectedDirectory() async throws -> AuthoritativeDirectory? {
    guard let storedData = await dependencies.bookmarkStore.load() else {
      return nil
    }
    let persisted = decodeAuthorization(storedData)
    let bookmark: ResolvedDirectoryBookmark
    do {
      bookmark = try dependencies.bookmarkCodec.resolve(persisted.bookmark)
    } catch {
      throw DirectoryAccessError.bookmarkMissing
    }
    guard !bookmark.isStale else {
      throw DirectoryAccessError.bookmarkStale
    }
    guard await dependencies.scopeAccess.startAccessing(bookmark.url) else {
      throw DirectoryAccessError.permissionDenied
    }
    guard isDirectory(bookmark.url) else {
      await dependencies.scopeAccess.stopAccessing(bookmark.url)
      throw DirectoryAccessError.directoryMoved
    }
    do {
      guard try dependencies.ubiquitousStatus.isDownloaded(bookmark.url) else {
        await dependencies.scopeAccess.stopAccessing(bookmark.url)
        throw DirectoryAccessError.itemNotDownloaded
      }
    } catch let error as DirectoryAccessError {
      throw error
    } catch {
      await dependencies.scopeAccess.stopAccessing(bookmark.url)
      throw DirectoryAccessError.unreadableDirectory
    }
    await dependencies.scopeAccess.stopAccessing(bookmark.url)
    if persisted.requiresMigration {
      try await dependencies.bookmarkStore.save(
        try JSONEncoder().encode(
          PersistedDirectoryAuthorization(
            id: persisted.id,
            bookmark: persisted.bookmark
          )
        )
      )
    }
    let directory = selectedDirectory(url: bookmark.url, id: persisted.id)
    resolvedRoots[directory.id] = ResolvedRoot(url: bookmark.url, directory: directory)
    return directory
  }

  public func authorizeSelectedDirectory(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    guard
      recordingReservations.isEmpty,
      transcriptionAccessMeetings.isEmpty,
      playbackScopedRoots.isEmpty
    else {
      throw DirectoryAccessError.coordinationFailed
    }
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
      let id =
        await existingDirectoryID(matching: url)
        ?? dependencies.makeUUID()
      try await dependencies.bookmarkStore.save(
        try JSONEncoder().encode(
          PersistedDirectoryAuthorization(id: id, bookmark: bookmark)
        )
      )
      await dependencies.scopeAccess.stopAccessing(url)
      let directory = selectedDirectory(url: url, id: id)
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
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw DirectoryAccessError.permissionDenied
    }
    guard isDirectory(root.url) else {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw DirectoryAccessError.directoryMoved
    }
    do {
      let scanner = scanner
      let rootURL = root.url
      let scanTask = Task.detached(priority: .utility) {
        try scanner.scan(rootURL)
      }
      let result = try await withTaskCancellationHandler {
        try await scanTask.value
      } onCancel: {
        scanTask.cancel()
      }
      await dependencies.scopeAccess.stopAccessing(root.url)
      return result
    } catch {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw error
    }
  }

  public func reserveRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation {
    guard recordingReservations[session.meetingID] == nil else {
      throw RecordingError.alreadyRecording
    }

    let root: ResolvedRoot
    do {
      root = try await recordingRoot()
    } catch {
      throw RecordingError.authoritativeDirectoryUnavailable
    }
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw RecordingError.authoritativeDirectoryUnavailable
    }
    let securityScopedRoot = root.url
    guard isDirectory(root.url) else {
      await dependencies.scopeAccess.stopAccessing(securityScopedRoot)
      throw RecordingError.authoritativeDirectoryUnavailable
    }

    do {
      if let capacity = try dependencies.availableCapacity(root.url),
        capacity < dependencies.minimumRecordingCapacityBytes
      {
        throw RecordingError.insufficientStorage
      }

      let directoryURL = availableMeetingDirectory(
        in: root.url,
        startedAt: session.startedAt
      )
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false
      )

      let reservation = RecordingFileReservation(
        meetingID: session.meetingID,
        createdAt: session.startedAt,
        directoryURL: directoryURL,
        recordingURL: directoryURL.appending(path: "recording.m4a")
      )
      recordingReservations[session.meetingID] = ActiveRecordingReservation(
        reservation: reservation,
        securityScopedRoot: securityScopedRoot
      )
      return reservation
    } catch {
      await dependencies.scopeAccess.stopAccessing(securityScopedRoot)
      throw error as? RecordingError ?? .authoritativeDirectoryUnavailable
    }
  }

  public func publishRecordingStart(
    _ reservation: RecordingFileReservation,
    startedAt: Date
  ) async throws {
    guard
      let active = recordingReservations[reservation.meetingID],
      active.reservation == reservation
    else {
      throw RecordingError.captureCouldNotStart
    }
    guard FileManager.default.fileExists(atPath: reservation.recordingURL.path)
    else {
      throw RecordingError.captureCouldNotStart
    }

    let manifest = MeetingManifest(
      meetingID: reservation.meetingID.rawValue,
      createdAt: startedAt
    )
    let data = try JSONEncoder.quillvaultManifest.encode(manifest)
    let manifestURL = reservation.directoryURL.appending(path: ".recording.json")
    let candidateURL = reservation.directoryURL.appending(
      path: ".meeting-\(dependencies.makeUUID().uuidString).tmp"
    )

    do {
      try captureEventStore.create(
        meetingID: reservation.meetingID,
        directoryURL: reservation.directoryURL
      )
      try coordinatedFiles.create(
        data,
        destinationURL: manifestURL,
        candidateURL: candidateURL
      )
      let published = try coordinatedFiles.readData(at: manifestURL)
      let decoded = try JSONDecoder().decode(MeetingManifest.self, from: published)
      guard
        decoded.schemaVersion == 1,
        decoded.meetingID == reservation.meetingID.rawValue
      else {
        throw RecordingError.recordingWriteFailed
      }
    } catch {
      try? removeCoordinatedItemIfPresent(at: candidateURL)
      try? captureEventStore.remove(directoryURL: reservation.directoryURL)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  public func recoverInterruptedRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation? {
    if let active = recordingReservations[session.meetingID] {
      return active.reservation
    }

    let root: ResolvedRoot
    do {
      root = try await recordingRoot()
    } catch {
      throw RecordingError.authoritativeDirectoryUnavailable
    }
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw RecordingError.authoritativeDirectoryUnavailable
    }

    let directoryURL: URL
    do {
      guard
        let recoveredDirectory = try interruptedRecordingDirectory(
          in: root.url,
          meetingID: session.meetingID
        )
      else {
        await dependencies.scopeAccess.stopAccessing(root.url)
        return nil
      }
      directoryURL = recoveredDirectory
    } catch {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw RecordingError.recordingWriteFailed
    }
    let recordingURL = directoryURL.appending(path: "recording.m4a")
    let pendingManifestURL = directoryURL.appending(path: ".recording.json")
    let publishedManifestURL = directoryURL.appending(path: "meeting.json")

    do {
      guard
        isDirectory(directoryURL),
        FileManager.default.fileExists(atPath: recordingURL.path),
        FileManager.default.fileExists(atPath: pendingManifestURL.path),
        !FileManager.default.fileExists(atPath: publishedManifestURL.path)
      else {
        await dependencies.scopeAccess.stopAccessing(root.url)
        return nil
      }
      guard try dependencies.ubiquitousStatus.isDownloaded(recordingURL) else {
        throw RecordingError.authoritativeDirectoryUnavailable
      }
      try validateManifest(
        at: pendingManifestURL,
        meetingID: session.meetingID
      )

      let reservation = RecordingFileReservation(
        meetingID: session.meetingID,
        createdAt: session.startedAt,
        directoryURL: directoryURL,
        recordingURL: recordingURL
      )
      recordingReservations[session.meetingID] = ActiveRecordingReservation(
        reservation: reservation,
        securityScopedRoot: root.url
      )
      let existingEvents = try await recordingCaptureEvents(
        meetingID: session.meetingID
      )
      let openGap = RecordingCaptureTimeline.gaps(in: existingEvents).last
      if openGap?.reason != .processTermination || openGap?.endedAt != nil {
        try await recordCaptureEvent(
          .interruptionBegan(
            at: try readCoordinatedModificationDate(at: recordingURL),
            reason: .processTermination
          ),
          meetingID: session.meetingID
        )
      }
      return reservation
    } catch {
      recordingReservations[session.meetingID] = nil
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  public func recordCaptureEvent(
    _ event: RecordingCaptureEvent,
    meetingID: MeetingID
  ) async throws {
    guard let active = recordingReservations[meetingID] else {
      throw RecordingError.noActiveRecording
    }
    do {
      try captureEventStore.append(
        event,
        meetingID: meetingID,
        directoryURL: active.reservation.directoryURL
      )
    } catch {
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  public func recordingCaptureEvents(
    meetingID: MeetingID
  ) async throws -> [RecordingCaptureEvent] {
    guard let active = recordingReservations[meetingID] else {
      throw RecordingError.noActiveRecording
    }
    return try captureEventStore.events(
      meetingID: meetingID,
      directoryURL: active.reservation.directoryURL
    )
  }

  public func reserveRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation {
    guard
      let active = recordingReservations[session.meetingID],
      continuationReservations[session.meetingID] == nil
    else {
      throw RecordingError.noActiveRecording
    }
    let reservation = try continuationTransaction.reserve(
      session: session,
      originalRecordingURL: active.reservation.recordingURL,
      directoryURL: active.reservation.directoryURL
    )
    continuationReservations[session.meetingID] = reservation
    return reservation
  }

  public func recoverRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation? {
    guard let active = recordingReservations[session.meetingID] else {
      throw RecordingError.noActiveRecording
    }
    if let cached = continuationReservations[session.meetingID] {
      return cached
    }
    let reservation = try continuationTransaction.recover(
      session: session,
      originalRecordingURL: active.reservation.recordingURL,
      directoryURL: active.reservation.directoryURL
    )
    if let reservation {
      continuationReservations[session.meetingID] = reservation
    }
    return reservation
  }

  public func commitRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async throws {
    guard
      continuationReservations[reservation.meetingID] == reservation
    else {
      throw RecordingError.recordingWriteFailed
    }
    try continuationTransaction.commit(reservation)
    continuationReservations[reservation.meetingID] = nil
  }

  public func cancelRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async {
    guard continuationReservations[reservation.meetingID] == reservation else {
      return
    }
    continuationTransaction.cancel(reservation)
    continuationReservations[reservation.meetingID] = nil
  }

  public func quarantineRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async {
    guard
      continuationReservations[reservation.meetingID] == reservation
        || continuationTransaction.exists(
          directoryURL: reservation.originalRecordingURL
            .deletingLastPathComponent()
        )
    else {
      return
    }
    continuationTransaction.quarantine(reservation)
    continuationReservations[reservation.meetingID] = nil
  }

  public func finishRecording(
    meetingID: MeetingID
  ) async throws {
    guard let active = recordingReservations[meetingID]
    else {
      throw RecordingError.noActiveRecording
    }
    let pendingURL = active.reservation.directoryURL.appending(
      path: ".recording.json"
    )
    let manifestURL = active.reservation.directoryURL.appending(
      path: "meeting.json"
    )

    var coordinationError: NSError?
    var publicationError: (any Error)?
    NSFileCoordinator().coordinate(
      readingItemAt: pendingURL,
      options: [],
      writingItemAt: manifestURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedPendingURL, coordinatedManifestURL in
      do {
        guard
          FileManager.default.fileExists(atPath: coordinatedPendingURL.path),
          !FileManager.default.fileExists(atPath: coordinatedManifestURL.path)
        else {
          throw RecordingError.recordingWriteFailed
        }
        try validateManifest(
          at: coordinatedPendingURL,
          meetingID: meetingID
        )
        try dependencies.fileMutator.move(
          itemAt: coordinatedPendingURL,
          to: coordinatedManifestURL
        )
        do {
          try validateManifest(
            at: coordinatedManifestURL,
            meetingID: meetingID
          )
        } catch {
          try? dependencies.fileMutator.move(
            itemAt: coordinatedManifestURL,
            to: coordinatedPendingURL
          )
          throw error
        }
      } catch {
        publicationError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let publicationError {
      throw publicationError
    }

    recordingReservations[meetingID] = nil
    if let securityScopedRoot = active.securityScopedRoot {
      await dependencies.scopeAccess.stopAccessing(securityScopedRoot)
    }
  }

  public func abandonRecording(
    meetingID: MeetingID
  ) async {
    guard let active = recordingReservations.removeValue(forKey: meetingID)
    else {
      return
    }
    if let securityScopedRoot = active.securityScopedRoot {
      await dependencies.scopeAccess.stopAccessing(securityScopedRoot)
    }
  }

  public func cancelRecording(
    meetingID: MeetingID
  ) async {
    guard let active = recordingReservations.removeValue(forKey: meetingID)
    else {
      return
    }
    try? removeCoordinatedItemIfPresent(
      at: active.reservation.directoryURL
    )
    if let securityScopedRoot = active.securityScopedRoot {
      await dependencies.scopeAccess.stopAccessing(securityScopedRoot)
    }
  }

  public func beginTranscriptionAccess(
    meetingID: MeetingID,
    recordingURL: URL
  ) async throws -> URL {
    guard !transcriptionAccessMeetings.contains(meetingID) else {
      guard let resolved = transcriptionRecordingURLs[meetingID] else {
        throw TranscriptError.recordingUnavailable
      }
      return resolved
    }
    let root: ResolvedRoot
    do {
      root = try await recordingRoot()
    } catch {
      throw TranscriptError.recordingUnavailable
    }
    let rootComponents = root.url.standardizedFileURL.pathComponents
    let storedParentName = recordingURL.deletingLastPathComponent().lastPathComponent
    let resolvedDirectoryURL = root.url.appending(
      path: storedParentName,
      directoryHint: .isDirectory
    )
    let resolvedRecordingURL = resolvedDirectoryURL.appending(path: "recording.m4a")
    guard
      recordingURL.isFileURL,
      recordingURL.lastPathComponent == "recording.m4a",
      storedParentName.hasPrefix("meeting-"),
      resolvedDirectoryURL.deletingLastPathComponent().standardizedFileURL
        == root.url.standardizedFileURL,
      resolvedRecordingURL.standardizedFileURL.pathComponents.count
        > rootComponents.count
    else {
      throw TranscriptError.recordingUnavailable
    }

    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw TranscriptError.recordingUnavailable
    }
    let scopedRoot = root.url
    guard isDirectory(root.url) else {
      await dependencies.scopeAccess.stopAccessing(scopedRoot)
      throw TranscriptError.recordingUnavailable
    }

    let manifestURL = resolvedDirectoryURL.appending(path: "meeting.json")
    guard
      FileManager.default.fileExists(atPath: resolvedRecordingURL.path),
      FileManager.default.fileExists(atPath: manifestURL.path),
      (try? validateManifest(at: manifestURL, meetingID: meetingID)) != nil
    else {
      await dependencies.scopeAccess.stopAccessing(scopedRoot)
      throw TranscriptError.recordingUnavailable
    }
    transcriptionAccessMeetings.insert(meetingID)
    transcriptionScopedRoots[meetingID] = scopedRoot
    transcriptionRecordingURLs[meetingID] = resolvedRecordingURL
    return resolvedRecordingURL
  }

  public func recoverableTranscriptionJobs(
    localeIdentifier: String
  ) async throws -> [TranscriptionJob] {
    guard let directory = try await restoreSelectedDirectory() else {
      return []
    }
    guard let root = resolvedRoots[directory.id] else {
      throw DirectoryAccessError.directoryMoved
    }
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw DirectoryAccessError.permissionDenied
    }
    do {
      let scan = try scanner.scan(root.url)
      let jobs: [TranscriptionJob] = try scan.meetings.compactMap { meeting in
        guard
          meeting.assets.contains(.recording),
          !meeting.assets.contains(.transcript)
        else {
          return nil
        }
        let recordingURL = root.url
          .appending(path: meeting.relativeDirectory, directoryHint: .isDirectory)
          .appending(path: "recording.m4a")
        let audioFile = try AVAudioFile(forReading: recordingURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
          throw TranscriptError.invalidAudioDuration
        }
        let duration = Double(audioFile.length) / sampleRate
        guard duration.isFinite, duration > 0 else {
          throw TranscriptError.invalidAudioDuration
        }
        return TranscriptionJob(
          meetingID: meeting.id,
          recordingURL: recordingURL,
          audioDurationSeconds: duration,
          localeIdentifier: localeIdentifier
        )
      }
      await dependencies.scopeAccess.stopAccessing(root.url)
      return jobs
    } catch {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw error
    }
  }

  public func endTranscriptionAccess(meetingID: MeetingID) async {
    guard transcriptionAccessMeetings.remove(meetingID) != nil else {
      return
    }
    if let root = transcriptionScopedRoots.removeValue(forKey: meetingID) {
      await dependencies.scopeAccess.stopAccessing(root)
    }
    transcriptionRecordingURLs[meetingID] = nil
  }

  private func removeCoordinatedItemIfPresent(at url: URL) throws {
    try coordinatedFiles.removeIfPresent(at: url)
  }

  private func readCoordinatedModificationDate(at url: URL) throws -> Date {
    try coordinatedFiles.readModificationDate(at: url)
  }

  private var scanner: MeetingDirectoryScanner {
    MeetingDirectoryScanner(
      ubiquitousStatus: dependencies.ubiquitousStatus
    )
  }

  private func recordingRoot() async throws -> ResolvedRoot {
    guard let directory = try await restoreSelectedDirectory() else {
      throw RecordingError.authoritativeDirectoryUnavailable
    }
    guard let root = resolvedRoots[directory.id] else {
      throw RecordingError.authoritativeDirectoryUnavailable
    }
    return root
  }

  private func selectedDirectory(
    url: URL,
    id: UUID
  ) -> AuthoritativeDirectory {
    return AuthoritativeDirectory(
      id: AuthoritativeDirectoryID(rawValue: id.uuidString.lowercased()),
      displayName: url.lastPathComponent,
      kind: .userSelected
    )
  }

  private func decodeAuthorization(
    _ data: Data
  ) -> (id: UUID, bookmark: Data, requiresMigration: Bool) {
    if let persisted = try? JSONDecoder().decode(
      PersistedDirectoryAuthorization.self,
      from: data
    ), persisted.schemaVersion == 1 {
      return (persisted.id, persisted.bookmark, false)
    }
    return (dependencies.makeUUID(), data, true)
  }

  private func existingDirectoryID(matching url: URL) async -> UUID? {
    guard let data = await dependencies.bookmarkStore.load() else {
      return nil
    }
    let persisted = decodeAuthorization(data)
    guard
      let resolved = try? dependencies.bookmarkCodec.resolve(
        persisted.bookmark
      ),
      resolved.url.standardizedFileURL == url.standardizedFileURL
    else {
      return nil
    }
    return persisted.id
  }

  private func availableMeetingDirectory(
    in root: URL,
    startedAt: Date
  ) -> URL {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let baseName = "meeting-\(formatter.string(from: startedAt))"
    var suffix = 1

    while true {
      let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
      let candidate = root.appending(
        path: name,
        directoryHint: .isDirectory
      )
      if !FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      suffix += 1
    }
  }

  private func interruptedRecordingDirectory(
    in root: URL,
    meetingID: MeetingID
  ) throws -> URL? {
    let children = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var matches: [URL] = []
    for child in children {
      guard
        child.lastPathComponent.hasPrefix("meeting-"),
        isDirectory(child)
      else {
        continue
      }
      let pendingManifestURL = child.appending(path: ".recording.json")
      let publishedManifestURL = child.appending(path: "meeting.json")
      let recordingURL = child.appending(path: "recording.m4a")
      guard
        FileManager.default.fileExists(atPath: pendingManifestURL.path),
        !FileManager.default.fileExists(atPath: publishedManifestURL.path),
        FileManager.default.fileExists(atPath: recordingURL.path),
        (try? validateManifest(
          at: pendingManifestURL,
          meetingID: meetingID
        )) != nil
      else {
        continue
      }
      matches.append(child)
    }
    guard matches.count <= 1 else {
      throw RecordingError.recordingWriteFailed
    }
    return matches.first
  }

  func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: url.path,
      isDirectory: &isDirectory
    ) && isDirectory.boolValue
  }

  private func validateManifest(
    at url: URL,
    meetingID: MeetingID
  ) throws {
    let data = try Data(contentsOf: url)
    let manifest = try JSONDecoder().decode(MeetingManifest.self, from: data)
    guard
      manifest.schemaVersion == 1,
      manifest.meetingID == meetingID.rawValue
    else {
      throw RecordingError.recordingWriteFailed
    }
    _ = try manifest.decodedCreationDate()
  }
}

extension MeetingFileStore: RecordingFileStore {}
extension MeetingFileStore: RecordingAssetAccess {}

extension JSONEncoder {
  static var quillvaultManifest: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
