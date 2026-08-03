import Application
import DesignSystem
import Domain
import SwiftUI
import UniformTypeIdentifiers

public struct HomeView: View {
  @Bindable private var model: HomeRecordingModel
  @State private var isDirectoryImporterPresented = false
  private let onOpenMeeting: ((MeetingID) -> Void)?

  public init(
    model: HomeRecordingModel,
    onOpenMeeting: ((MeetingID) -> Void)? = nil
  ) {
    self.model = model
    self.onOpenMeeting = onOpenMeeting
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
    case .interrupted(_, let audio):
      Label {
        VStack(alignment: .leading, spacing: QuillvaultSpacing.compact) {
          Text("recording.interrupted.title")
            .font(.headline)
          Text(
            Duration.seconds(audio.durationSeconds),
            format: .time(pattern: .minuteSecond)
          )
          .foregroundStyle(.secondary)
          Text("recording.interrupted.message")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          if !model.interruptionGaps.isEmpty {
            Divider()
            RecordingInterruptionTimelineView(gaps: model.interruptionGaps)
          }
          Button {
            Task {
              await model.resumeInterrupted()
            }
          } label: {
            Label(
              "recording.interrupted.resume",
              systemImage: "record.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("recording.interrupted.resume")
          Button {
            Task {
              await model.startNewAfterInterruption()
            }
          } label: {
            Label(
              "recording.interrupted.startNew",
              systemImage: "plus.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("recording.interrupted.startNew")
          Button {
            Task {
              await model.finishInterrupted()
            }
          } label: {
            Label(
              "recording.interrupted.finish",
              systemImage: "checkmark.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("recording.interrupted.finish")
        }
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: .rect(cornerRadius: 20))
    case .completed(let completion):
      processingResultCard(completion: completion)
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

  @ViewBuilder
  private func processingResultCard(
    completion: RecordingCompletion
  ) -> some View {
    Label {
      VStack(alignment: .leading, spacing: QuillvaultSpacing.compact) {
        Text(processingTitle)
          .font(.headline)
          .accessibilityIdentifier("home.processing.title")
        Text(
          Duration.seconds(completion.audio.durationSeconds),
          format: .time(pattern: .minuteSecond)
        )
        .foregroundStyle(.secondary)

        processingBody

        if let meetingID = model.focusedMeetingID, let onOpenMeeting {
          Button {
            onOpenMeeting(meetingID)
          } label: {
            Label("home.processing.openDetail", systemImage: "doc.text")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("home.processing.openDetail")
        }
      }
    } icon: {
      Image(systemName: processingSystemImage)
        .foregroundStyle(processingTint)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 20))
    .accessibilityIdentifier("home.processing.card")
  }

  private var processingTitle: LocalizedStringKey {
    switch model.processingPhase {
    case .idle:
      "recording.completed"
    case .finalizingTranscript:
      "home.processing.transcript.running"
    case .transcriptFailed:
      "home.processing.transcript.failed"
    case .awaitingMinutes:
      "home.processing.minutes.pending"
    case .generatingMinutes:
      "home.processing.minutes.running"
    case .generationPaused:
      "home.processing.minutes.paused"
    case .minutesCompleted:
      "home.processing.minutes.completed"
    case .generationFailed:
      "home.processing.minutes.failed"
    }
  }

  private var processingSystemImage: String {
    switch model.processingPhase {
    case .idle, .minutesCompleted:
      "checkmark.circle.fill"
    case .finalizingTranscript, .generatingMinutes:
      "arrow.triangle.2.circlepath.circle.fill"
    case .awaitingMinutes:
      "sparkles"
    case .generationPaused:
      "pause.circle.fill"
    case .transcriptFailed, .generationFailed:
      "exclamationmark.circle.fill"
    }
  }

  private var processingTint: Color {
    switch model.processingPhase {
    case .idle, .minutesCompleted:
      .green
    case .finalizingTranscript, .generatingMinutes, .awaitingMinutes:
      .accentColor
    case .generationPaused:
      .orange
    case .transcriptFailed, .generationFailed:
      .orange
    }
  }

  @ViewBuilder
  private var processingBody: some View {
    switch model.processingPhase {
    case .idle:
      EmptyView()
    case .finalizingTranscript:
      HStack(spacing: QuillvaultSpacing.compact) {
        ProgressView()
        Text("home.processing.transcript.running.description")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("home.processing.transcript.running")
    case .transcriptFailed(let error):
      Text(error.transcriptRecoveryMessageKey)
        .font(.footnote)
        .foregroundStyle(.orange)
      Button {
        Task {
          await model.retryTranscript()
        }
      } label: {
        if model.transcriptRecoveryState == .retrying {
          ProgressView()
        } else {
          Label("recording.transcript.retry", systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(.bordered)
      .disabled(model.transcriptRecoveryState == .retrying)
      .accessibilityIdentifier("home.processing.transcript.retry")
    case .awaitingMinutes:
      Text("home.processing.minutes.pending.description")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Button {
        Task {
          await model.startMinutesGeneration()
        }
      } label: {
        Label("minutes.generation.start", systemImage: "sparkles")
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("home.processing.minutes.start")
    case .generatingMinutes(let snapshot):
      VStack(alignment: .leading, spacing: QuillvaultSpacing.compact) {
        HStack {
          ProgressView()
          Text(snapshot.job.stage.homeStageKey)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(snapshot.job.progress)%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        ProgressView(value: Double(snapshot.job.progress), total: 100)
        Text("home.processing.minutes.running.description")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(
          "minutes.generation.progress \(snapshot.job.completedChunkCount) \(snapshot.job.chunkCount)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("home.processing.minutes.running")
    case .generationPaused(let snapshot):
      Text("home.processing.minutes.paused.description")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if let reason = snapshot.job.pauseReason {
        Text(reason.homeMessageKey)
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      Button {
        Task {
          await model.startMinutesGeneration()
        }
      } label: {
        Label("minutes.generation.resume", systemImage: "play.circle")
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("home.processing.minutes.resume")
    case .minutesCompleted:
      Text("home.processing.minutes.completed.description")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    case .generationFailed:
      Text("home.processing.minutes.failed.description")
        .font(.subheadline)
        .foregroundStyle(.orange)
      Button {
        Task {
          await model.startMinutesGeneration()
        }
      } label: {
        Label("minutes.generation.start", systemImage: "sparkles")
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("home.processing.minutes.retry")
    }
  }
}

extension TranscriptError {
  fileprivate var transcriptRecoveryMessageKey: LocalizedStringKey {
    switch self {
    case .unsupportedLocale:
      "recording.transcript.failure.locale"
    case .speechAssetsUnavailable:
      "recording.transcript.failure.assets"
    case .recordingUnavailable:
      "recording.transcript.failure.recording"
    case .publicationFailed:
      "recording.transcript.failure.publication"
    case .invalidAudioDuration, .invalidTimeRange, .recognitionFailed:
      "recording.transcript.failure.recognition"
    }
  }
}

extension GenerationPauseReason {
  fileprivate var homeMessageKey: LocalizedStringKey {
    switch self {
    case .networkUnavailable:
      "home.processing.minutes.pause.network"
    case .credentialsUnavailable, .authenticationRequired:
      "home.processing.minutes.pause.credentials"
    case .modelUnavailable, .rateLimited, .serviceUnavailable, .retryableRequest,
      .invalidResponse, .retryExhausted, .requestTooLarge, .unavailable:
      "home.processing.minutes.pause.service"
    case .cancelled, .sourceChanged, .publicationFailed, .externalMinutesChanged:
      "home.processing.minutes.paused.description"
    }
  }
}

extension GenerationStage {
  fileprivate var homeStageKey: LocalizedStringKey {
    switch self {
    case .pending:
      "home.processing.minutes.stage.pending"
    case .summarizing:
      "home.processing.minutes.stage.summarizing"
    case .synthesizing:
      "home.processing.minutes.stage.synthesizing"
    case .normalizing:
      "home.processing.minutes.stage.normalizing"
    case .publishing:
      "home.processing.minutes.stage.publishing"
    case .completed:
      "home.processing.minutes.stage.completed"
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
