import Domain
import SwiftUI

struct MeetingTranscriptSection: View {
  let original: MeetingTranscriptAsset
  let optimized: MeetingTranscriptAsset
  let selectedVersion: TranscriptVersionKind
  let isComparing: Bool
  let canOptimize: Bool
  let optimizeBusy: Bool
  let optimizeError: Bool
  let selectVersion: (TranscriptVersionKind) -> Void
  let setComparing: (Bool) -> Void
  let optimize: () -> Void
  let seekAndPlay: (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("minutes.detail.transcript", systemImage: "text.quote")
        .font(.title2.bold())
        .accessibilityIdentifier("minutes.detail.transcript.heading")

      if hasOptimized {
        Picker(
          "minutes.detail.transcript.version",
          selection: Binding(
            get: { selectedVersion },
            set: { selectVersion($0) }
          )
        ) {
          Text("minutes.detail.transcript.version.original")
            .tag(TranscriptVersionKind.original)
          Text("minutes.detail.transcript.version.optimized")
            .tag(TranscriptVersionKind.optimized)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("minutes.detail.transcript.version")

        // Generation prefers the optimized asset when present; original stays immutable.
        Label(
          "minutes.detail.transcript.generationSource.optimized",
          systemImage: "sparkles"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("minutes.detail.transcript.generationSource")

        Toggle(
          "minutes.detail.transcript.compare",
          isOn: Binding(
            get: { isComparing },
            set: { setComparing($0) }
          )
        )
        .accessibilityIdentifier("minutes.detail.transcript.compare")
      }

      if canOptimize {
        Button {
          optimize()
        } label: {
          if optimizeBusy {
            ProgressView()
          } else {
            Label(
              "minutes.detail.transcript.optimize",
              systemImage: "text.badge.checkmark"
            )
          }
        }
        .disabled(optimizeBusy)
        .buttonStyle(.bordered)
        .accessibilityIdentifier("minutes.detail.transcript.optimize")
        if optimizeError {
          Text("minutes.detail.transcript.optimize.failed")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }

      if isComparing, hasOptimized {
        compareContent
      } else {
        transcriptBody(displayedAsset)
      }
    }
    .accessibilityIdentifier("minutes.detail.transcript.section")
  }

  private var hasOptimized: Bool {
    if case .available = optimized {
      return true
    }
    return false
  }

  private var displayedAsset: MeetingTranscriptAsset {
    switch selectedVersion {
    case .original:
      return original
    case .optimized:
      if case .available = optimized {
        return optimized
      }
      return original
    }
  }

  @ViewBuilder
  private var compareContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("minutes.detail.transcript.version.original")
        .font(.headline)
      transcriptBody(original)
      Divider()
      Text("minutes.detail.transcript.version.optimized")
        .font(.headline)
      transcriptBody(optimized)
    }
  }

  @ViewBuilder
  private func transcriptBody(_ transcript: MeetingTranscriptAsset) -> some View {
    switch transcript {
    case .available(let timeline):
      if timeline.segments.isEmpty {
        Text("minutes.detail.transcript.empty")
          .foregroundStyle(.secondary)
      } else {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(timeline.segments, id: \.id) { segment in
            Button {
              seekAndPlay(segment.startSeconds)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(anchor(for: segment))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.tint)
                Text(segment.text)
                  .foregroundStyle(.primary)
                  .multilineTextAlignment(.leading)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              Text(
                "minutes.detail.transcript.seek \(anchor(for: segment)) \(segment.text)"
              )
            )
            .accessibilityIdentifier(
              "minutes.detail.transcript.segment.\(segment.id)"
            )
          }
        }
      }
    case .missing:
      Text("minutes.detail.transcript.pending")
        .foregroundStyle(.secondary)
    case .downloadRequired:
      Label(
        "minutes.detail.download.required",
        systemImage: "icloud.and.arrow.down"
      )
      .foregroundStyle(.secondary)
    case .unreadable:
      Label(
        "minutes.detail.transcript.unreadable",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.secondary)
    }
  }

  private func anchor(for segment: TranscriptSegment) -> String {
    let candidate = TranscriptSegmentCandidate(
      startSeconds: segment.startSeconds,
      endSeconds: segment.endSeconds,
      text: segment.text
    )
    let line = TranscriptAnchorFormatter.line(for: candidate)
    guard let close = line.firstIndex(of: "]") else {
      return ""
    }
    return String(line[line.index(after: line.startIndex)...close])
  }
}
