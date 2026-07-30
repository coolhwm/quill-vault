import Domain
import Foundation

struct RecordingContinuationTransaction: Sendable {
  private let files: CoordinatedRecordingFileAccess
  private let mutator: any RecordingFileMutating
  private let makeUUID: @Sendable () -> UUID

  init(
    files: CoordinatedRecordingFileAccess,
    mutator: any RecordingFileMutating,
    makeUUID: @escaping @Sendable () -> UUID
  ) {
    self.files = files
    self.mutator = mutator
    self.makeUUID = makeUUID
  }

  func exists(directoryURL: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: manifestURL(directoryURL: directoryURL).path
    )
  }

  func reserve(
    session: RecordingSession,
    originalRecordingURL: URL,
    directoryURL: URL
  ) throws -> RecordingContinuationReservation {
    guard !exists(directoryURL: directoryURL) else {
      throw RecordingError.noActiveRecording
    }
    let token = makeUUID().uuidString
    let reservation = RecordingContinuationReservation(
      meetingID: session.meetingID,
      originalRecordingURL: originalRecordingURL,
      continuationURL: directoryURL.appending(
        path: ".recording-continuation-\(token).m4a"
      ),
      candidateURL: directoryURL.appending(
        path: ".recording-merged-\(token).m4a"
      )
    )
    guard
      !FileManager.default.fileExists(
        atPath: reservation.continuationURL.path
      ),
      !FileManager.default.fileExists(
        atPath: reservation.candidateURL.path
      )
    else {
      throw RecordingError.recordingWriteFailed
    }
    try writeManifest(
      RecordingContinuationManifest(reservation: reservation),
      directoryURL: directoryURL
    )
    return reservation
  }

  func recover(
    session: RecordingSession,
    originalRecordingURL: URL,
    directoryURL: URL
  ) throws -> RecordingContinuationReservation? {
    guard exists(directoryURL: directoryURL) else {
      return nil
    }
    let manifest = try JSONDecoder().decode(
      RecordingContinuationManifest.self,
      from: files.readData(at: manifestURL(directoryURL: directoryURL))
    )
    guard manifest.meetingID == session.meetingID.rawValue else {
      throw RecordingError.recordingWriteFailed
    }
    let reservation = try manifest.reservation(
      directoryURL: directoryURL,
      originalRecordingURL: originalRecordingURL
    )
    if manifest.state == .prepared,
      let expectedDigest = manifest.candidateDigest,
      FileManager.default.fileExists(atPath: originalRecordingURL.path),
      try files.readDigest(at: originalRecordingURL) == expectedDigest
    {
      removeArtifacts(reservation, removeContinuation: true)
      return nil
    }
    guard
      FileManager.default.fileExists(
        atPath: reservation.continuationURL.path
      )
        || FileManager.default.fileExists(
          atPath: reservation.candidateURL.path
        )
    else {
      removeArtifacts(reservation, removeContinuation: true)
      return nil
    }
    return reservation
  }

  func commit(_ reservation: RecordingContinuationReservation) throws {
    guard
      FileManager.default.fileExists(
        atPath: reservation.originalRecordingURL.path
      ),
      FileManager.default.fileExists(
        atPath: reservation.continuationURL.path
      ),
      FileManager.default.fileExists(
        atPath: reservation.candidateURL.path
      )
    else {
      throw RecordingError.recordingWriteFailed
    }

    let originalDigest = try files.readDigest(
      at: reservation.originalRecordingURL
    )
    let candidateDigest = try files.readDigest(at: reservation.candidateURL)
    let directoryURL = reservation.originalRecordingURL.deletingLastPathComponent()
    try writeManifest(
      RecordingContinuationManifest(reservation: reservation)
        .prepared(candidateDigest: candidateDigest),
      directoryURL: directoryURL
    )

    let backupName =
      ".recording-before-continuation-\(makeUUID().uuidString).m4a"
    let backupURL = directoryURL.appending(path: backupName)
    var coordinationError: NSError?
    var replacementError: (any Error)?
    NSFileCoordinator().coordinate(
      writingItemAt: reservation.originalRecordingURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedURL in
      do {
        try mutator.replace(
          itemAt: coordinatedURL,
          with: reservation.candidateURL,
          backupItemName: backupName,
          keepBackup: true
        )
      } catch {
        replacementError = error
      }
    }

    if coordinationError != nil {
      try restoreBackup(
        originalURL: reservation.originalRecordingURL,
        backupURL: backupURL,
        expectedDigest: originalDigest
      )
      throw RecordingError.recordingWriteFailed
    }
    if let replacementError {
      try restoreBackup(
        originalURL: reservation.originalRecordingURL,
        backupURL: backupURL,
        expectedDigest: originalDigest
      )
      throw replacementError as? RecordingError
        ?? .recordingWriteFailed
    }
    guard
      FileManager.default.fileExists(
        atPath: reservation.originalRecordingURL.path
      ),
      (try? files.readDigest(
        at: reservation.originalRecordingURL
      )) == candidateDigest
    else {
      try restoreBackup(
        originalURL: reservation.originalRecordingURL,
        backupURL: backupURL,
        expectedDigest: originalDigest
      )
      throw RecordingError.recordingWriteFailed
    }

    try? files.removeIfPresent(at: backupURL)
    removeArtifacts(reservation, removeContinuation: true)
  }

  func cancel(_ reservation: RecordingContinuationReservation) {
    try? files.removeIfPresent(at: reservation.candidateURL)
    let attributes = try? FileManager.default.attributesOfItem(
      atPath: reservation.continuationURL.path
    )
    let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    if byteCount == 0 {
      removeArtifacts(reservation, removeContinuation: true)
    }
  }

  func quarantine(_ reservation: RecordingContinuationReservation) {
    if FileManager.default.fileExists(
      atPath: reservation.continuationURL.path
    ) {
      let quarantineURL = reservation.originalRecordingURL
        .deletingLastPathComponent()
        .appending(
          path: "recording-recovery-\(makeUUID().uuidString).m4a"
        )
      try? files.move(
        at: reservation.continuationURL,
        to: quarantineURL
      )
    }
    removeArtifacts(reservation, removeContinuation: false)
  }

  private func manifestURL(directoryURL: URL) -> URL {
    directoryURL.appending(path: ".recording-continuation.json")
  }

  private func writeManifest(
    _ manifest: RecordingContinuationManifest,
    directoryURL: URL
  ) throws {
    try files.write(
      try JSONEncoder.quillvaultManifest.encode(manifest),
      destinationURL: manifestURL(directoryURL: directoryURL),
      candidateURL: directoryURL.appending(
        path:
          ".recording-continuation-\(makeUUID().uuidString).json.tmp"
      )
    )
  }

  private func removeArtifacts(
    _ reservation: RecordingContinuationReservation,
    removeContinuation: Bool
  ) {
    let directoryURL = reservation.originalRecordingURL
      .deletingLastPathComponent()
    try? files.removeIfPresent(at: manifestURL(directoryURL: directoryURL))
    try? files.removeIfPresent(at: reservation.candidateURL)
    if removeContinuation {
      try? files.removeIfPresent(at: reservation.continuationURL)
    }
  }

  private func restoreBackup(
    originalURL: URL,
    backupURL: URL,
    expectedDigest: String
  ) throws {
    guard FileManager.default.fileExists(atPath: backupURL.path) else {
      return
    }
    do {
      try files.replaceOrMove(at: backupURL, to: originalURL)
      guard
        FileManager.default.fileExists(atPath: originalURL.path),
        try files.readDigest(at: originalURL) == expectedDigest
      else {
        throw RecordingError.recordingWriteFailed
      }
    } catch {
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }
}
