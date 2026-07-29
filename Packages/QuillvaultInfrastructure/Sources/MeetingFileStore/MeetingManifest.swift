import Foundation

struct MeetingManifest: Codable {
  let schemaVersion: Int
  let meetingID: UUID
  let createdAt: String

  init(meetingID: UUID, createdAt: Date) {
    schemaVersion = 1
    self.meetingID = meetingID
    self.createdAt = ISO8601DateFormatter().string(from: createdAt)
  }

  func decodedCreationDate() throws -> Date {
    guard schemaVersion == 1 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    guard let date = ISO8601DateFormatter().date(from: createdAt) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return date
  }
}
