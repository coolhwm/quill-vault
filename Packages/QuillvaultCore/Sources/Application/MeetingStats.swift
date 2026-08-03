import Domain
import Foundation

/// Local-only meeting usage statistics derived from the rebuildable catalog.
public struct MeetingStats: Equatable, Sendable {
  public let meetingCount: Int
  public let totalDurationSeconds: Double
  public let monthMeetingCount: Int
  public let monthDurationSeconds: Double
  /// Daily duration seconds keyed by start-of-day in the provided calendar.
  public let dailyDurationSeconds: [Date: Double]

  public init(
    meetingCount: Int,
    totalDurationSeconds: Double,
    monthMeetingCount: Int,
    monthDurationSeconds: Double,
    dailyDurationSeconds: [Date: Double]
  ) {
    self.meetingCount = meetingCount
    self.totalDurationSeconds = totalDurationSeconds
    self.monthMeetingCount = monthMeetingCount
    self.monthDurationSeconds = monthDurationSeconds
    self.dailyDurationSeconds = dailyDurationSeconds
  }

  public static let empty = MeetingStats(
    meetingCount: 0,
    totalDurationSeconds: 0,
    monthMeetingCount: 0,
    monthDurationSeconds: 0,
    dailyDurationSeconds: [:]
  )

  public static func make(
    from meetings: [MeetingIndexEntry],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> MeetingStats {
    let monthStart =
      calendar.date(from: calendar.dateComponents([.year, .month], from: now))
      ?? now
    let nextMonth =
      calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now

    var totalDuration: Double = 0
    var monthCount = 0
    var monthDuration: Double = 0
    var daily: [Date: Double] = [:]

    for meeting in meetings {
      let duration = max(0, meeting.durationSeconds ?? 0)
      totalDuration += duration
      if meeting.createdAt >= monthStart, meeting.createdAt < nextMonth {
        monthCount += 1
        monthDuration += duration
      }
      let day = calendar.startOfDay(for: meeting.createdAt)
      daily[day, default: 0] += duration
    }

    return MeetingStats(
      meetingCount: meetings.count,
      totalDurationSeconds: totalDuration,
      monthMeetingCount: monthCount,
      monthDurationSeconds: monthDuration,
      dailyDurationSeconds: daily
    )
  }

  /// Relative intensity in `0...1` for heatmap coloring by daily duration.
  public func intensity(on day: Date, calendar: Calendar = .current) -> Double {
    let key = calendar.startOfDay(for: day)
    let value = dailyDurationSeconds[key] ?? 0
    let peak = dailyDurationSeconds.values.max() ?? 0
    guard peak > 0 else {
      return 0
    }
    return min(1, max(0, value / peak))
  }
}
