import Domain
import SwiftUI

public struct MeetingDetailView: View {
  @State private var model: MeetingDetailModel

  public init(model: MeetingDetailModel) {
    _model = State(initialValue: model)
  }

  public var body: some View {
    Group {
      switch model.state {
      case .idle, .loading:
        loadingShell
      case .failed:
        ContentUnavailableView(
          "minutes.detail.failed.title",
          systemImage: "exclamationmark.triangle",
          description: Text("minutes.detail.failed.description")
        )
      case .loaded(let detail):
        detailContent(detail)
      }
    }
    .navigationTitle("minutes.detail.navigation.title")
    .meetingDetailTitleStyle()
    .task {
      await model.load()
    }
    .onDisappear {
      model.unload()
    }
    .alert(
      "minutes.generation.replace.title",
      isPresented: Binding(
        get: { model.requiresMinutesReplacementConfirmation },
        set: { isPresented in
          if !isPresented {
            model.dismissMinutesReplacementConfirmation()
          }
        }
      )
    ) {
      Button("minutes.generation.replace.confirm") {
        Task {
          await model.regenerateGeneration(replacingExternalMinutes: true)
        }
      }
      Button("minutes.generation.replace.cancel", role: .cancel) {
        model.dismissMinutesReplacementConfirmation()
      }
    } message: {
      Text("minutes.generation.replace.description")
    }
    .accessibilityIdentifier("minutes.detail.screen")
  }

  private var loadingShell: some View {
    VStack(alignment: .leading, spacing: 16) {
      ProgressView()
      Text("minutes.loading")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("minutes.detail.loading")
  }

  private func detailContent(_ detail: MeetingDetail) -> some View {
    VStack(spacing: 0) {
      Picker(
        "minutes.detail.tab",
        selection: Binding(
          get: { model.selectedDetailTab },
          set: { model.selectDetailTab($0) }
        )
      ) {
        Text("minutes.detail.tab.smartMinutes")
          .tag(MeetingDetailModel.MeetingDetailTab.smartMinutes)
        Text("minutes.detail.tab.transcript")
          .tag(MeetingDetailModel.MeetingDetailTab.transcript)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.top, 8)
      .accessibilityIdentifier("minutes.detail.tab")

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          switch model.selectedDetailTab {
          case .smartMinutes:
            smartMinutesContent(detail)
          case .transcript:
            transcriptContent(detail)
          }
        }
        .padding()
        .safeAreaPadding(.bottom, 120)
      }
    }
  }

  @ViewBuilder
  private func smartMinutesContent(_ detail: MeetingDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        "minutes.detail.title.placeholder",
        text: Binding(
          get: { model.draftTitle },
          set: { model.draftTitle = $0 }
        )
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityIdentifier("minutes.detail.title.field")
      HStack {
        Button {
          Task {
            await model.saveTitle()
          }
        } label: {
          if model.titleSaveBusy {
            ProgressView()
          } else {
            Label("minutes.detail.title.save", systemImage: "checkmark.circle")
          }
        }
        .buttonStyle(.bordered)
        .disabled(model.titleSaveBusy)
        .accessibilityIdentifier("minutes.detail.title.save")
        if model.titleSaveError {
          Text("minutes.detail.title.save.failed")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
    }

    MeetingGenerationSection(
      minutes: detail.minutes,
      snapshot: model.generationSnapshot,
      isBusy: model.generationBusy,
      hasError: model.generationError,
      isMinutesExpired: detail.meeting.status == .minutesExpired,
      modelProfiles: model.generationProfiles,
      selectedModelProfileID: model.selectedGenerationProfileID,
      start: {
        Task {
          await model.startGeneration()
        }
      },
      resume: {
        Task {
          await model.resumeGeneration()
        }
      },
      cancel: {
        Task {
          await model.cancelGeneration()
        }
      },
      regenerate: {
        Task {
          await model.regenerateGeneration()
        }
      },
      selectModelProfile: { profileID in
        Task {
          await model.selectGenerationProfile(profileID)
        }
      }
    )
    // Markdown view renders fenced mermaid inline; avoid a second diagram stack.
    MeetingSummarySection(minutes: detail.minutes)
  }

  @ViewBuilder
  private func transcriptContent(_ detail: MeetingDetail) -> some View {
    MeetingAudioPlayerSection(
      recording: detail.recording,
      playback: model.playback,
      playbackFailed: model.playbackFailed,
      toggle: model.togglePlayback,
      seek: { seconds in
        model.seek(to: seconds, beginsPlayback: false)
      },
      retry: {
        Task {
          await model.retryPlayback()
        }
      }
    )
    MeetingTranscriptSection(
      original: detail.transcript,
      optimized: detail.optimizedTranscript,
      selectedVersion: model.selectedTranscriptVersion,
      isComparing: model.isComparingTranscripts,
      canOptimize: {
        if case .available = detail.transcript {
          return true
        }
        return false
      }(),
      optimizeBusy: model.transcriptOptimizeBusy,
      optimizeError: model.transcriptOptimizeError,
      selectVersion: { model.selectTranscriptVersion($0) },
      setComparing: { model.setTranscriptCompare($0) },
      optimize: {
        Task {
          await model.optimizeTranscript()
        }
      },
      seekAndPlay: { seconds in
        model.seek(to: seconds, beginsPlayback: true)
      }
    )
  }
}

extension View {
  @ViewBuilder
  fileprivate func meetingDetailTitleStyle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}
