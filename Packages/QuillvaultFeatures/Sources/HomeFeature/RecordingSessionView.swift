import DesignSystem
import Domain
import SwiftUI

struct RecordingSessionView: View {
  @Bindable var model: HomeRecordingModel

  var body: some View {
    NavigationStack {
      VStack(spacing: QuillvaultSpacing.spacious) {
        status
        elapsedTime
        liveTranscript
        stopAction
      }
      .padding(QuillvaultSpacing.spacious)
      .navigationTitle("recording.navigation.title")
      .recordingNavigationTitleStyle()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("recording.screen")
    }
  }

  private var liveTranscript: some View {
    GroupBox("recording.transcript.title") {
      ScrollView {
        Text(
          model.liveTranscriptText.isEmpty
            ? String(localized: "recording.transcript.waiting")
            : model.liveTranscriptText
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(
          model.liveTranscriptText.isEmpty ? .secondary : .primary
        )
        .textSelection(.enabled)
      }
      .frame(maxHeight: .infinity)
    }
    .accessibilityIdentifier("recording.transcript")
  }

  private var status: some View {
    Label {
      Text(statusKey)
        .font(.title.bold())
    } icon: {
      Image(systemName: statusSymbol)
        .font(.title)
        .foregroundStyle(statusColor)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var elapsedTime: some View {
    if let session {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let seconds = max(
          0,
          context.date.timeIntervalSince(session.startedAt)
        )
        Text(
          Duration.seconds(seconds),
          format: .time(pattern: .hourMinuteSecond)
        )
        .font(.system(.largeTitle, design: .rounded).monospacedDigit().bold())
        .contentTransition(.numericText())
        .accessibilityLabel("recording.elapsed")
        .accessibilityValue(
          Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds]))
        )
      }
    }
  }

  @ViewBuilder
  private var stopAction: some View {
    switch model.state {
    case .recording:
      Button(role: .destructive) {
        Task {
          await model.stop()
        }
      } label: {
        Label("recording.stop", systemImage: "stop.circle.fill")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .accessibilityIdentifier("recording.stop")
      .accessibilityHint("recording.stop.hint")
    case .finishing:
      ProgressView("recording.finishing")
        .controlSize(.large)
        .accessibilityIdentifier("recording.finishing")
    case .finishFailed(_, let error):
      RecordingFailureCard(error: error) {
        Task {
          await model.stop()
        }
      }
    case .idle, .starting, .completed, .startFailed:
      EmptyView()
    }
  }

  private var session: RecordingSession? {
    switch model.state {
    case .recording(let session),
      .finishing(let session),
      .finishFailed(let session, _):
      session
    case .idle, .starting, .completed, .startFailed:
      nil
    }
  }

  private var statusKey: LocalizedStringKey {
    switch model.state {
    case .recording:
      "recording.active"
    case .finishing:
      "recording.finishing"
    case .finishFailed:
      "recording.finish.failed"
    case .idle, .starting, .completed, .startFailed:
      "recording.active"
    }
  }

  private var statusSymbol: String {
    switch model.state {
    case .recording:
      "record.circle.fill"
    case .finishing:
      "hourglass"
    case .finishFailed:
      "exclamationmark.triangle.fill"
    case .idle, .starting, .completed, .startFailed:
      "record.circle.fill"
    }
  }

  private var statusColor: Color {
    switch model.state {
    case .recording:
      .red
    case .finishing:
      .orange
    case .finishFailed:
      .red
    case .idle, .starting, .completed, .startFailed:
      .red
    }
  }
}
