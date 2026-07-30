import Domain
import SwiftUI

struct MeetingCardView: View {
  let meeting: MeetingIndexEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if let title = meeting.title {
          Text(title)
        } else {
          Text("minutes.card.default.title")
        }
      }
      .font(.headline)
      Text(meeting.createdAt, format: .dateTime.year().month().day().hour().minute())
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Label(durationText, systemImage: "clock")
        Text(statusKey)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      if let modelName = meeting.modelName {
        Label(modelName, systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private var durationText: String {
    guard let duration = meeting.durationSeconds else {
      return "--:--"
    }
    let seconds = max(0, Int(duration.rounded()))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private var statusKey: LocalizedStringKey {
    if meeting.assets.contains(.minutes) {
      return "minutes.status.completed"
    }
    if meeting.assets.contains(.transcript) {
      return "minutes.status.awaiting.minutes"
    }
    return "minutes.status.awaiting.transcript"
  }
}
