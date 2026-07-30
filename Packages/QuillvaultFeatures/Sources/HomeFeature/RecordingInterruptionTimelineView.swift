import Domain
import SwiftUI

struct RecordingInterruptionTimelineView: View {
  let gaps: [RecordingInterruptionGap]

  var body: some View {
    GroupBox {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
            VStack(alignment: .leading, spacing: 2) {
              Label(gap.reason.messageKey, systemImage: "timeline.selection")
                .font(.footnote)
              HStack(spacing: 4) {
                Text(
                  gap.startedAt,
                  format: .dateTime.hour().minute().second()
                )
                Text("–")
                if gap.didResume, let endedAt = gap.endedAt {
                  Text(
                    endedAt,
                    format: .dateTime.hour().minute().second()
                  )
                } else {
                  Text("recording.interrupted.timeline.unresolved")
                }
              }
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 120)
    } label: {
      Label(
        "recording.interrupted.timeline",
        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
      )
    }
    .accessibilityIdentifier("recording.interruption.timeline")
  }
}
