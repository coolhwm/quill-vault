import Domain
import SwiftUI

struct MeetingAudioPlayerSection: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let recording: MeetingRecordingAsset
  let playback: MeetingAudioPlaybackSnapshot
  let playbackFailed: Bool
  let toggle: () -> Void
  let seek: (Double) -> Void
  var retry: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("minutes.detail.recording", systemImage: "waveform")
        .font(.title2.bold())
        .accessibilityIdentifier("minutes.detail.recording.heading")
      switch recording {
      case .available:
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 12) {
            playbackButton
            timeRange
            progressSlider
          }
        } else {
          HStack {
            playbackButton
            Text(time(playback.currentSeconds))
              .monospacedDigit()
            progressSlider
            Text(time(playback.durationSeconds))
              .monospacedDigit()
          }
        }
        if playbackFailed {
          Label(
            "minutes.detail.recording.playback.failed",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
          if let retry {
            Button {
              retry()
            } label: {
              Label(
                "minutes.detail.recording.playback.retry",
                systemImage: "arrow.clockwise"
              )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("minutes.detail.recording.playback.retry")
          }
        }
      case .missing:
        Label("minutes.detail.recording.missing", systemImage: "waveform.slash")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("minutes.detail.recording.missing")
      case .downloadRequired:
        Label("minutes.detail.download.required", systemImage: "icloud.and.arrow.down")
          .foregroundStyle(.secondary)
      case .unreadable:
        Label("minutes.detail.recording.unreadable", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("minutes.detail.recording.section")
  }

  private var playbackButton: some View {
    Button(action: toggle) {
      Label(
        playback.isPlaying
          ? "minutes.detail.recording.pause"
          : "minutes.detail.recording.play",
        systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
      )
    }
    .buttonStyle(.borderedProminent)
    .accessibilityIdentifier("minutes.detail.recording.toggle")
  }

  private var progressSlider: some View {
    Slider(
      value: Binding(
        get: { playback.currentSeconds },
        set: { seconds in
          seek(seconds)
        }
      ),
      in: 0...max(0.1, playback.durationSeconds)
    )
    .accessibilityIdentifier("minutes.detail.recording.slider")
  }

  private var timeRange: some View {
    HStack {
      Text(time(playback.currentSeconds))
        .monospacedDigit()
      Spacer()
      Text(time(playback.durationSeconds))
        .monospacedDigit()
    }
  }

  private func time(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", value / 60, value % 60)
  }
}
