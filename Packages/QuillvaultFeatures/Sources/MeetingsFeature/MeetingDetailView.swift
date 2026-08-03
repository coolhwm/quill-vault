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
    .accessibilityIdentifier("minutes.detail.screen")
  }

  private var loadingShell: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach(
          [
            ("minutes.detail.summary", "text.alignleft"),
            (
              "minutes.detail.diagram",
              "point.3.connected.trianglepath.dotted"
            ),
            ("minutes.detail.transcript", "text.quote"),
            ("minutes.detail.recording", "waveform"),
          ],
          id: \.0
        ) { title, image in
          Label(LocalizedStringKey(title), systemImage: image)
            .font(.title2.bold())
          ProgressView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
    }
    .accessibilityIdentifier("minutes.detail.loading")
  }

  private func detailContent(_ detail: MeetingDetail) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        MeetingGenerationSection(
          minutes: detail.minutes,
          snapshot: model.generationSnapshot,
          isBusy: model.generationBusy,
          hasError: model.generationError,
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
          }
        )
        MeetingSummarySection(minutes: detail.minutes)
        MeetingDiagramSection(minutes: detail.minutes)
        MeetingAudioPlayerSection(
          recording: detail.recording,
          playback: model.playback,
          playbackFailed: model.playbackFailed,
          toggle: model.togglePlayback,
          seek: { seconds in
            model.seek(to: seconds, beginsPlayback: false)
          }
        )
        MeetingTranscriptSection(
          transcript: detail.transcript,
          seekAndPlay: { seconds in
            model.seek(to: seconds, beginsPlayback: true)
          }
        )
      }
      .padding()
      .safeAreaPadding(.bottom, 120)
    }
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
