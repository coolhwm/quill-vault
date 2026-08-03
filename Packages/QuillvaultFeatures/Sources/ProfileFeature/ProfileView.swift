import Application
import DesignSystem
import Domain
import SettingsFeature
import SwiftUI

public struct ProfileView: View {
  @Bindable private var model: ProfileModel
  private let settingsModel: SettingsModel

  public init(model: ProfileModel, settingsModel: SettingsModel) {
    self.model = model
    self.settingsModel = settingsModel
  }

  public var body: some View {
    List {
      Section("profile.stats.section") {
        if model.isLoading {
          ProgressView("profile.stats.loading")
        } else if model.loadFailed {
          Text("profile.stats.failed")
            .foregroundStyle(.secondary)
        } else {
          LabeledContent("profile.stats.meetings") {
            Text("\(model.stats.meetingCount)")
              .monospacedDigit()
          }
          LabeledContent("profile.stats.total_duration") {
            Text(durationText(model.stats.totalDurationSeconds))
              .monospacedDigit()
          }
          LabeledContent("profile.stats.month_meetings") {
            Text("\(model.stats.monthMeetingCount)")
              .monospacedDigit()
          }
          LabeledContent("profile.stats.month_duration") {
            Text(durationText(model.stats.monthDurationSeconds))
              .monospacedDigit()
          }
        }
      }

      Section("profile.heatmap.section") {
        MeetingHeatmapView(stats: model.stats)
          .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
      }

      Section {
        NavigationLink {
          SettingsView(model: settingsModel)
        } label: {
          Label("profile.settings", systemImage: "gearshape")
        }
        .accessibilityIdentifier("profile.settings")
      }
    }
    .navigationTitle("profile.navigation.title")
    .accessibilityIdentifier("profile.screen")
    .task {
      await model.load()
    }
    .refreshable {
      await model.load()
    }
  }

  private func durationText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    if hours > 0 {
      return String(format: "%dh %02dm", hours, minutes)
    }
    return String(format: "%dm", minutes)
  }
}

struct MeetingHeatmapView: View {
  let stats: MeetingStats
  private let calendar = Calendar.current
  private let weeks = 12
  private let daysInWeek = 7

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("profile.heatmap.caption")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 3) {
        ForEach(0..<weeks, id: \.self) { week in
          VStack(spacing: 3) {
            ForEach(0..<daysInWeek, id: \.self) { weekday in
              let day = dayDate(weekOffset: week, weekdayIndex: weekday)
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color(for: day))
                .frame(width: 12, height: 12)
                .accessibilityLabel(accessibilityLabel(for: day))
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("profile.heatmap")
    }
  }

  private func dayDate(weekOffset: Int, weekdayIndex: Int) -> Date {
    let today = calendar.startOfDay(for: Date())
    // Align columns so the last column ends on today.
    let daysFromStartOfGrid =
      (weeks - 1 - weekOffset) * 7 + (daysInWeek - 1 - weekdayIndex)
    return calendar.date(byAdding: .day, value: -daysFromStartOfGrid, to: today)
      ?? today
  }

  private func color(for day: Date) -> Color {
    let intensity = stats.intensity(on: day, calendar: calendar)
    if intensity <= 0 {
      return Color.secondary.opacity(0.12)
    }
    return Color.accentColor.opacity(0.25 + 0.75 * intensity)
  }

  private func accessibilityLabel(for day: Date) -> String {
    let seconds = stats.dailyDurationSeconds[calendar.startOfDay(for: day)] ?? 0
    let minutes = Int((seconds / 60).rounded())
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return "\(formatter.string(from: day)): \(minutes)m"
  }
}
