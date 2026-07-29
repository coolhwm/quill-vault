import DesignSystem
import SwiftUI

public struct HomeView: View {
  @Bindable private var model: HomeRecordingModel

  public init(model: HomeRecordingModel) {
    self.model = model
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuillvaultSpacing.spacious) {
        header
        recordingAction
        resultCard
      }
      .padding(QuillvaultSpacing.standard)
    }
    .accessibilityIdentifier("home.screen")
    .recordingSessionPresentation(
      isPresented: Binding(
        get: { model.isSessionPresented },
        set: { _ in }
      ),
      model: model
    )
    .alert(
      "recording.notice.title",
      isPresented: $model.isRecordingNoticePresented
    ) {
      Button("recording.notice.confirm") {
        Task {
          await model.acknowledgeNoticeAndStart()
        }
      }
      Button("recording.notice.cancel", role: .cancel) {}
    } message: {
      Text("recording.notice.message")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: QuillvaultSpacing.compact) {
      Text("Quillvault")
        .font(.largeTitle.bold())
      Text("home.subtitle")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  private var recordingAction: some View {
    VStack(alignment: .leading, spacing: QuillvaultSpacing.standard) {
      Image(systemName: "waveform.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      Text("home.recording.title")
        .font(.title2.bold())
      Text("home.recording.description")
        .foregroundStyle(.secondary)

      Button {
        Task {
          await model.start()
        }
      } label: {
        Label(
          model.state == .starting
            ? "recording.starting"
            : "recording.start",
          systemImage: "record.circle"
        )
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(model.state == .starting)
      .accessibilityIdentifier("recording.start")
      .accessibilityHint("recording.start.hint")
    }
    .padding(QuillvaultSpacing.spacious)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 24))
  }

  @ViewBuilder
  private var resultCard: some View {
    switch model.state {
    case .completed(let completion):
      Label {
        VStack(alignment: .leading, spacing: QuillvaultSpacing.compact) {
          Text("recording.completed")
            .font(.headline)
          Text(
            Duration.seconds(completion.audio.durationSeconds),
            format: .time(pattern: .minuteSecond)
          )
          .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: .rect(cornerRadius: 20))
    case .startFailed(let error):
      RecordingFailureCard(error: error) {
        Task {
          await model.start()
        }
      }
    case .idle, .starting, .recording, .finishing, .finishFailed:
      EmptyView()
    }
  }
}
