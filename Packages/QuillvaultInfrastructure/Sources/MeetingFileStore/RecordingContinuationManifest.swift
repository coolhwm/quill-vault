import CryptoKit
import Domain
import Foundation

struct RecordingContinuationManifest: Codable, Equatable {
  enum State: String, Codable {
    case recording
    case prepared
  }

  let schemaVersion: Int
  let meetingID: UUID
  let continuationFileName: String
  let candidateFileName: String
  let state: State
  let candidateDigest: String?

  init(reservation: RecordingContinuationReservation) {
    schemaVersion = 1
    meetingID = reservation.meetingID.rawValue
    continuationFileName = reservation.continuationURL.lastPathComponent
    candidateFileName = reservation.candidateURL.lastPathComponent
    state = .recording
    candidateDigest = nil
  }

  private init(
    schemaVersion: Int,
    meetingID: UUID,
    continuationFileName: String,
    candidateFileName: String,
    state: State,
    candidateDigest: String?
  ) {
    self.schemaVersion = schemaVersion
    self.meetingID = meetingID
    self.continuationFileName = continuationFileName
    self.candidateFileName = candidateFileName
    self.state = state
    self.candidateDigest = candidateDigest
  }

  func prepared(candidateDigest: String) -> Self {
    Self(
      schemaVersion: schemaVersion,
      meetingID: meetingID,
      continuationFileName: continuationFileName,
      candidateFileName: candidateFileName,
      state: .prepared,
      candidateDigest: candidateDigest
    )
  }

  func reservation(
    directoryURL: URL,
    originalRecordingURL: URL
  ) throws -> RecordingContinuationReservation {
    guard
      schemaVersion == 1,
      continuationFileName.hasPrefix(".recording-continuation-"),
      continuationFileName.hasSuffix(".m4a"),
      candidateFileName.hasPrefix(".recording-merged-"),
      candidateFileName.hasSuffix(".m4a"),
      continuationFileName != candidateFileName,
      !continuationFileName.contains("/"),
      !candidateFileName.contains("/")
    else {
      throw RecordingError.recordingWriteFailed
    }
    let reservation = RecordingContinuationReservation(
      meetingID: MeetingID(rawValue: meetingID),
      originalRecordingURL: originalRecordingURL,
      continuationURL: directoryURL.appending(
        path: continuationFileName
      ),
      candidateURL: directoryURL.appending(path: candidateFileName)
    )
    guard
      reservation.originalRecordingURL.deletingLastPathComponent()
        .standardizedFileURL == directoryURL.standardizedFileURL,
      reservation.continuationURL.deletingLastPathComponent()
        .standardizedFileURL == directoryURL.standardizedFileURL,
      reservation.candidateURL.deletingLastPathComponent()
        .standardizedFileURL == directoryURL.standardizedFileURL,
      reservation.originalRecordingURL.standardizedFileURL
        != reservation.continuationURL.standardizedFileURL,
      reservation.originalRecordingURL.standardizedFileURL
        != reservation.candidateURL.standardizedFileURL
    else {
      throw RecordingError.recordingWriteFailed
    }
    return reservation
  }

  static func digest(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
