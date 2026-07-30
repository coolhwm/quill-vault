import Domain
import SwiftUI

struct MeetingTranscriptSection: View {
  let transcript: MeetingTranscriptAsset
  let seekAndPlay: (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("minutes.detail.transcript", systemImage: "text.quote")
        .font(.title2.bold())
        .accessibilityIdentifier("minutes.detail.transcript.heading")
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
                Text("minutes.detail.transcript.seek \(anchor(for: segment)) \(segment.text)")
              )
              .accessibilityIdentifier("minutes.detail.transcript.segment.\(segment.id)")
            }
          }
        }
      case .missing:
        Text("minutes.detail.transcript.pending")
          .foregroundStyle(.secondary)
      case .downloadRequired:
        Label("minutes.detail.download.required", systemImage: "icloud.and.arrow.down")
          .foregroundStyle(.secondary)
      case .unreadable:
        Label("minutes.detail.transcript.unreadable", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("minutes.detail.transcript.section")
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
