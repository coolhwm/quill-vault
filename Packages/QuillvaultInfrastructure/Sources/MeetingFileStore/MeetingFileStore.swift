import CryptoKit
import Domain
import Foundation

public actor MeetingFileStore: AuthoritativeDirectoryAccess {
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

  public func reserveRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation {
    guard recordingReservations[session.meetingID] == nil else {
      throw RecordingError.alreadyRecording
    }

    let root = try await recordingRoot()
    let securityScopedRoot: URL?
    if root.directory.kind == .userSelected {
      guard await dependencies.scopeAccess.startAccessing(root.url) else {
        throw RecordingError.authoritativeDirectoryUnavailable
      }
      securityScopedRoot = root.url
    } else {
      securityScopedRoot = nil
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
      if let securityScopedRoot {
        await dependencies.scopeAccess.stopAccessing(securityScopedRoot)
      }
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

  private var scanner: MeetingDirectoryScanner {
    MeetingDirectoryScanner(
      ubiquitousStatus: dependencies.ubiquitousStatus
    )
  }

  private func recordingRoot() async throws -> ResolvedRoot {
    let directory: AuthoritativeDirectory
    if let selected = try await restoreSelectedDirectory() {
      directory = selected
    } else {
      directory = try await resolveDefaultDirectory()
    }
    guard let root = resolvedRoots[directory.id], isDirectory(root.url) else {
      throw RecordingError.authoritativeDirectoryUnavailable
    }
    return root
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

extension JSONEncoder {
  fileprivate static var quillvaultManifest: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
