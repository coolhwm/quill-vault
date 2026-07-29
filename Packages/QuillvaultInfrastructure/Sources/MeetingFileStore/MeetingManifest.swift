import Foundation

struct MeetingManifest: Decodable {
  let schemaVersion: Int
  let meetingID: UUID
  let createdAt: String

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
