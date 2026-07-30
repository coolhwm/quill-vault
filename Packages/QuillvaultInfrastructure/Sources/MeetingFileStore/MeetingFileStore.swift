import Domain
import Foundation

public actor MeetingFileStore: AuthoritativeDirectoryAccess {
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

  private struct ResolvedRoot: Sendable {
    let url: URL
    let directory: AuthoritativeDirectory
  }

  private struct ActiveRecordingReservation: Sendable {
    let reservation: RecordingFileReservation
    let securityScopedRoot: URL?
  }

  private let dependencies: MeetingFileStoreDependencies
  private var resolvedRoots: [AuthoritativeDirectoryID: ResolvedRoot] = [:]
  private var recordingReservations: [MeetingID: ActiveRecordingReservation] = [:]
  private var transcriptionAccessMeetings = Set<MeetingID>()
  private var transcriptionScopedRoots: [MeetingID: URL] = [:]
  private var transcriptionRecordingURLs: [MeetingID: URL] = [:]

  public init() {
    dependencies = .live()
  }

  init(dependencies: MeetingFileStoreDependencies) {
    self.dependencies = dependencies
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
      transcriptionAccessMeetings.isEmpty
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
      let id = await existingDirectoryID(matching: url) ?? UUID()
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
      let result = try scanner.scan(root.url)
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

      let directoryURL = root.url.appending(
        path: "meeting-\(session.meetingID.rawValue.uuidString.lowercased())",
        directoryHint: .isDirectory
      )
      guard !FileManager.default.fileExists(atPath: directoryURL.path) else {
        throw RecordingError.captureCouldNotStart
      }
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
      path: ".meeting-\(UUID().uuidString).tmp"
    )

    do {
      guard
        FileManager.default.createFile(
          atPath: candidateURL.path,
          contents: nil
        )
      else {
        throw RecordingError.recordingWriteFailed
      }
      let handle = try FileHandle(forWritingTo: candidateURL)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()

      var coordinationError: NSError?
      var replacementError: (any Error)?
      NSFileCoordinator().coordinate(
        writingItemAt: manifestURL,
        options: .forReplacing,
        error: &coordinationError
      ) { coordinatedURL in
        do {
          guard !FileManager.default.fileExists(atPath: coordinatedURL.path)
          else {
            throw RecordingError.captureCouldNotStart
          }
          try FileManager.default.moveItem(
            at: candidateURL,
            to: coordinatedURL
          )
        } catch {
          replacementError = error
        }
      }
      if let coordinationError {
        throw coordinationError
      }
      if let replacementError {
        throw replacementError
      }

      let published = try Data(contentsOf: manifestURL)
      let decoded = try JSONDecoder().decode(MeetingManifest.self, from: published)
      guard
        decoded.schemaVersion == 1,
        decoded.meetingID == reservation.meetingID.rawValue
      else {
        throw RecordingError.recordingWriteFailed
      }
    } catch {
      try? FileManager.default.removeItem(at: candidateURL)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
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
        try FileManager.default.moveItem(
          at: coordinatedPendingURL,
          to: coordinatedManifestURL
        )
        do {
          try validateManifest(
            at: coordinatedManifestURL,
            meetingID: meetingID
          )
        } catch {
          try? FileManager.default.moveItem(
            at: coordinatedManifestURL,
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
    try? FileManager.default.removeItem(at: active.reservation.directoryURL)
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
    let resolvedRecordingURL = root.url.appending(
      path: "meeting-\(meetingID.rawValue.uuidString.lowercased())",
      directoryHint: .isDirectory
    ).appending(path: "recording.m4a")
    let storedParentName = recordingURL.deletingLastPathComponent().lastPathComponent
    guard
      recordingURL.isFileURL,
      recordingURL.lastPathComponent == "recording.m4a",
      storedParentName
        == "meeting-\(meetingID.rawValue.uuidString.lowercased())",
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

    guard FileManager.default.fileExists(atPath: resolvedRecordingURL.path) else {
      await dependencies.scopeAccess.stopAccessing(scopedRoot)
      throw TranscriptError.recordingUnavailable
    }
    transcriptionAccessMeetings.insert(meetingID)
    transcriptionScopedRoots[meetingID] = scopedRoot
    transcriptionRecordingURLs[meetingID] = resolvedRecordingURL
    return resolvedRecordingURL
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
    return (UUID(), data, true)
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

  private func isDirectory(_ url: URL) -> Bool {
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
  fileprivate static var quillvaultManifest: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
