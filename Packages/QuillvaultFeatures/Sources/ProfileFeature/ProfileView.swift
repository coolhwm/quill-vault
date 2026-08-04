import Application
import DesignSystem
import Domain
import SwiftUI

/// Profile / Me tab. Settings is injected by the app shell so Profile does not
/// depend on the Settings feature module (architecture boundary).
public struct ProfileView<SettingsDestination: View>: View {
  @Bindable private var model: ProfileModel
  private let settingsDestination: SettingsDestination

  public init(
    model: ProfileModel,
    @ViewBuilder settingsDestination: () -> SettingsDestination
  ) {
    self.model = model
    self.settingsDestination = settingsDestination()
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
          .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
      }

      Section {
        NavigationLink {
          settingsDestination
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

/// Near-12-month contribution-style grid sized to available width.
struct MeetingHeatmapView: View {
  let stats: MeetingStats
  private let calendar = Calendar.current
  /// ~52 weeks covers about 12 months.
  private let weeks = 53
  private let daysInWeek = 7

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("profile.heatmap.caption")
        .font(.caption)
        .foregroundStyle(.secondary)

      GeometryReader { geometry in
        let spacing: CGFloat = 2
        let cell = max(
          3,
          floor((geometry.size.width - spacing * CGFloat(weeks - 1)) / CGFloat(weeks))
        )
        VStack(alignment: .leading, spacing: 4) {
          monthLabels(cellWidth: cell, spacing: spacing)
          HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { week in
              VStack(spacing: spacing) {
                ForEach(0..<daysInWeek, id: \.self) { weekday in
                  let day = dayDate(weekOffset: week, weekdayIndex: weekday)
                  RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(for: day))
                    .frame(width: cell, height: cell)
                    .accessibilityLabel(accessibilityLabel(for: day))
                }
              }
            }
          }
          legend
        }
      }
      .frame(height: heatmapHeight)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("profile.heatmap")
    }
  }

  private var heatmapHeight: CGFloat {
    // Month labels + 7 rows of cells (approx) + legend
    18 + 7 * 12 + 20
  }

  private func monthLabels(cellWidth: CGFloat, spacing: CGFloat) -> some View {
    let labels = monthLabelEntries(cellWidth: cellWidth, spacing: spacing)
    return ZStack(alignment: .leading) {
      ForEach(labels, id: \.offset) { entry in
        Text(entry.label)
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
          .offset(x: entry.x)
      }
    }
    .frame(height: 14)
  }

  private func monthLabelEntries(
    cellWidth: CGFloat,
    spacing: CGFloat
  ) -> [(offset: Int, label: String, x: CGFloat)] {
    var result: [(offset: Int, label: String, x: CGFloat)] = []
    var lastMonth: Int?
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("MMM")
    for week in 0..<weeks {
      let day = dayDate(weekOffset: week, weekdayIndex: 0)
      let month = calendar.component(.month, from: day)
      if month != lastMonth {
        lastMonth = month
        let x = CGFloat(week) * (cellWidth + spacing)
        result.append((week, formatter.string(from: day), x))
      }
    }
    return result
  }

  private var legend: some View {
    HStack(spacing: 4) {
      Text("profile.heatmap.less")
        .font(.caption2)
        .foregroundStyle(.secondary)
      ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { intensity in
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(swatch(intensity))
          .frame(width: 10, height: 10)
      }
      Text("profile.heatmap.more")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  private func dayDate(weekOffset: Int, weekdayIndex: Int) -> Date {
    let today = calendar.startOfDay(for: Date())
    let daysFromStartOfGrid =
      (weeks - 1 - weekOffset) * 7 + (daysInWeek - 1 - weekdayIndex)
    return calendar.date(byAdding: .day, value: -daysFromStartOfGrid, to: today)
      ?? today
  }

  private func color(for day: Date) -> Color {
    swatch(stats.intensity(on: day, calendar: calendar))
  }

  private func swatch(_ intensity: Double) -> Color {
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
