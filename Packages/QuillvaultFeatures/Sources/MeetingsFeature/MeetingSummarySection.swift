import Domain
import SwiftUI

struct MeetingSummarySection: View {
  let minutes: MeetingMarkdownAsset

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("minutes.detail.summary", systemImage: "text.alignleft")
        .font(.title2.bold())
      switch minutes {
      case .available(let content):
        Text(content.summaryMarkdown)
          .textSelection(.enabled)
      case .missing:
        Text("minutes.detail.summary.pending")
          .foregroundStyle(.secondary)
      case .downloadRequired:
        Label("minutes.detail.download.required", systemImage: "icloud.and.arrow.down")
          .foregroundStyle(.secondary)
      case .unreadable:
        Label("minutes.detail.summary.unreadable", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("minutes.detail.summary.section")
  }

}
