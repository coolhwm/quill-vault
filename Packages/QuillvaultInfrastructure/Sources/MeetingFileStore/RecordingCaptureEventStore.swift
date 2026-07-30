import Domain
import Foundation

struct RecordingCaptureEventStore: Sendable {
  private let files: CoordinatedRecordingFileAccess
  private let makeUUID: @Sendable () -> UUID

  init(
    files: CoordinatedRecordingFileAccess,
    makeUUID: @escaping @Sendable () -> UUID
  ) {
    self.files = files
    self.makeUUID = makeUUID
  }

  func create(meetingID: MeetingID, directoryURL: URL) throws {
    let data = try JSONEncoder.quillvaultManifest.encode(
      RecordingCaptureEventLog(meetingID: meetingID.rawValue)
    )
    try files.create(
      data,
      destinationURL: eventLogURL(directoryURL: directoryURL),
      candidateURL: candidateURL(directoryURL: directoryURL)
    )
  }

  func append(
    _ event: RecordingCaptureEvent,
    meetingID: MeetingID,
    directoryURL: URL
  ) throws {
    let published = try files.update(
      destinationURL: eventLogURL(directoryURL: directoryURL),
      candidateURL: candidateURL(directoryURL: directoryURL)
    ) { currentData in
      let current = try JSONDecoder().decode(
        RecordingCaptureEventLog.self,
        from: currentData
      )
      guard
        current.schemaVersion == 1,
        current.meetingID == meetingID.rawValue
      else {
        throw RecordingError.recordingWriteFailed
      }
      return try JSONEncoder.quillvaultManifest.encode(
        current.appending(event)
      )
    }
    let confirmed = try JSONDecoder().decode(
      RecordingCaptureEventLog.self,
      from: published
    )
    guard
      confirmed.meetingID == meetingID.rawValue,
      confirmed.events.last == event
    else {
      throw RecordingError.recordingWriteFailed
    }
  }

  func events(meetingID: MeetingID, directoryURL: URL) throws
    -> [RecordingCaptureEvent]
  {
    let log = try JSONDecoder().decode(
      RecordingCaptureEventLog.self,
      from: files.readData(at: eventLogURL(directoryURL: directoryURL))
    )
    guard log.schemaVersion == 1, log.meetingID == meetingID.rawValue else {
      throw RecordingError.recordingWriteFailed
    }
    return log.events
  }

  func remove(directoryURL: URL) throws {
    try files.removeIfPresent(at: eventLogURL(directoryURL: directoryURL))
  }

  private func eventLogURL(directoryURL: URL) -> URL {
    directoryURL.appending(path: ".recording-events.json")
  }

  private func candidateURL(directoryURL: URL) -> URL {
    directoryURL.appending(
      path: ".recording-events-\(makeUUID().uuidString).json.tmp"
    )
  }
}
