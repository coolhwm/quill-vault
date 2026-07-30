import Domain
import Foundation

struct RecordingCaptureEventLog: Codable, Equatable {
  let schemaVersion: Int
  let meetingID: UUID
  let events: [RecordingCaptureEvent]

  init(meetingID: UUID) {
    schemaVersion = 1
    self.meetingID = meetingID
    events = []
  }

  private init(
    schemaVersion: Int,
    meetingID: UUID,
    events: [RecordingCaptureEvent]
  ) {
    self.schemaVersion = schemaVersion
    self.meetingID = meetingID
    self.events = events
  }

  func appending(_ event: RecordingCaptureEvent) -> Self {
    guard events.last != event else {
      return self
    }
    return Self(
      schemaVersion: schemaVersion,
      meetingID: meetingID,
      events: events + [event]
    )
  }
}
