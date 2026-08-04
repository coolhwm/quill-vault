import Application
import Domain
import SwiftUI

struct MeetingCardView: View {
  let meeting: MeetingIndexEntry
  var processingPhase: MeetingProcessingPhase?

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
      if let progress = processingPhase?.progressPercent {
        ProgressView(value: Double(progress), total: 100)
          .accessibilityIdentifier("minutes.card.progress")
        Text("\(progress)%")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
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
    if let processingPhase {
      switch processingPhase {
      case .finalizingTranscript, .awaitingTranscript:
        return "minutes.status.awaiting.transcript"
      case .optimizingTranscript:
        return "home.processing.optimize.running"
      case .optimizeFailed:
        return "home.processing.optimize.failed"
      case .generatingMinutes:
        return "home.processing.minutes.running"
      case .generationPaused:
        return "home.processing.minutes.paused"
      case .generationFailed:
        return "home.processing.minutes.failed"
      case .awaitingMinutes:
        return "minutes.status.awaiting.minutes"
      case .minutesCompleted:
        return "minutes.status.completed"
      case .minutesExpired:
        return "minutes.status.expired"
      case .transcriptFailed:
        return "home.processing.transcript.failed"
      case .idle:
        break
      }
    }
    switch meeting.status {
    case .awaitingTranscript:
      return "minutes.status.awaiting.transcript"
    case .awaitingMinutes:
      return "minutes.status.awaiting.minutes"
    case .minutesCompleted:
      return "minutes.status.completed"
    case .minutesExpired:
      return "minutes.status.expired"
    }
  }
}
