import Application
import Domain
import Foundation
import Testing

@Suite("Meeting stats")
struct MeetingStatsTests {
  @Test("Aggregates total and month stats from local meetings")
  func aggregatesTotals() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_735_689_600)  // 2025-01-01 UTC
    let meetings = [
      MeetingIndexEntry(
        id: MeetingID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
        createdAt: Date(timeIntervalSince1970: 1_735_689_600),
        relativeDirectory: "a",
        assets: [.recording],
        durationSeconds: 600
      ),
      MeetingIndexEntry(
        id: MeetingID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
        createdAt: Date(timeIntervalSince1970: 1_730_000_000),  // previous month-ish
        relativeDirectory: "b",
        assets: [.recording],
        durationSeconds: 1_200
      ),
    ]

    let stats = MeetingStats.make(
      from: meetings,
      now: now,
      calendar: calendar
    )
    #expect(stats.meetingCount == 2)
    #expect(stats.totalDurationSeconds == 1_800)
    #expect(stats.monthMeetingCount == 1)
    #expect(stats.monthDurationSeconds == 600)
    #expect(stats.intensity(on: now, calendar: calendar) > 0)
  }

  @Test("Empty catalog yields zero stats")
  func emptyCatalog() {
    #expect(MeetingStats.make(from: []) == .empty)
  }
}
