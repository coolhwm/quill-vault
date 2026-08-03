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
        if content.informationMayBeIncomplete {
          Label(
            "minutes.detail.incomplete",
            systemImage: "info.circle"
          )
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("minutes.detail.incomplete")
        }
        MeetingMarkdownText(markdown: content.summaryMarkdown)
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

private struct MeetingMarkdownText: View {
  let markdown: String

  private var blocks: [String] {
    markdown
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 14) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        if let attributed = try? AttributedString(markdown: block) {
          Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text(block)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}
