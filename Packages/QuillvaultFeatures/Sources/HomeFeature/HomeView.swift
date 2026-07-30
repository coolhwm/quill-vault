import Application
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

public struct HomeView: View {
  @Bindable private var model: HomeRecordingModel
  @State private var isDirectoryImporterPresented = false

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
    .task {
      await model.restore()
    }
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
    .fileImporter(
      isPresented: $isDirectoryImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        return
      }
      Task {
        await model.selectDirectory(opaqueReference: url.absoluteString)
      }
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
        switch directoryRecovery {
        case .chooseDirectory, .renewAccess:
          isDirectoryImporterPresented = true
        case .downloadRequired, .tryAgain:
          Task {
            await model.refreshDirectory()
          }
        case nil:
          Task {
            await model.start()
          }
        }
      } label: {
        Label(
          recordingActionTitle,
          systemImage: recordingActionSystemImage
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

      directoryStatus
    }
    .padding(QuillvaultSpacing.spacious)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 24))
  }

  private var recordingActionTitle: LocalizedStringKey {
    switch directoryRecovery {
    case .chooseDirectory:
      return "home.directory.choose"
    case .renewAccess:
      return "home.directory.reauthorize"
    case .downloadRequired, .tryAgain:
      return "home.directory.retry"
    case nil:
      return model.state == .starting
        ? "recording.starting"
        : "recording.start"
    }
  }

  private var recordingActionSystemImage: String {
    switch directoryRecovery {
    case .chooseDirectory, .renewAccess:
      "folder.badge.plus"
    case .downloadRequired, .tryAgain:
      "arrow.clockwise"
    case nil:
      "record.circle"
    }
  }

  private var directoryRecovery: AuthoritativeDirectoryRecovery? {
    guard case .recoveryRequired(let recovery) = model.directoryState else {
      return nil
    }
    return recovery
  }

  @ViewBuilder
  private var directoryStatus: some View {
    switch model.directoryState {
    case .checking:
      Label("home.directory.checking", systemImage: "folder")
        .foregroundStyle(.secondary)
    case .recoveryRequired(let recovery):
      Label(recovery.homeStatusKey, systemImage: "exclamationmark.folder")
        .foregroundStyle(.orange)
    case .authorized(let directory):
      Label(directory.displayName, systemImage: "folder.fill")
        .foregroundStyle(.secondary)
    }
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

extension AuthoritativeDirectoryRecovery {
  fileprivate var homeStatusKey: LocalizedStringKey {
    switch self {
    case .chooseDirectory:
      "home.directory.required"
    case .renewAccess:
      "home.directory.access.expired"
    case .downloadRequired:
      "home.directory.download.required"
    case .tryAgain:
      "home.directory.unavailable"
    }
  }
}
