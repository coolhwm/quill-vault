import Application
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
        MinutesMarkdownView(markdown: content.summaryMarkdown)
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

/// Renders minutes Markdown with fenced mermaid isolated for offline diagrams.
struct MinutesMarkdownView: View {
  let markdown: String

  var body: some View {
    let blocks = MinutesMarkdownDocument.blocks(from: markdown)
    LazyVStack(alignment: .leading, spacing: 16) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .markdown(let text):
          markdownBlock(text)
        case .mermaid(let source):
          #if canImport(WebKit)
            MermaidDiagramView(source: source)
          #else
            Text(source)
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
          #endif
        }
      }
    }
    .accessibilityIdentifier("minutes.detail.markdown")
  }

  @ViewBuilder
  private func markdownBlock(_ text: String) -> some View {
    if let attributed = try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
      )
    ) {
      Text(attributed)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text(text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
