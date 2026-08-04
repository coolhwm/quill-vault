import Application
import Domain
import Foundation
import SwiftUI

struct MeetingSummarySection: View {
  let minutes: MeetingMarkdownAsset
  var onChapterSeek: ((Double) -> Void)? = nil

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
        MinutesMarkdownView(
          markdown: content.summaryMarkdown,
          onChapterSeek: onChapterSeek
        )
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
/// Uses block-level styling so headings/lists are visually hierarchical (walkthrough #45).
struct MinutesMarkdownView: View {
  let markdown: String
  var onChapterSeek: ((Double) -> Void)?

  var body: some View {
    let blocks = MinutesMarkdownDocument.blocks(from: markdown)
    LazyVStack(alignment: .leading, spacing: 16) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .markdown(let text):
          styledMarkdownBlock(text)
        case .mermaid(let source):
          #if canImport(WebKit)
            MermaidDiagramView(source: source, preferredHeight: 200)
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
  private func styledMarkdownBlock(_ text: String) -> some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        markdownLine(line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func markdownLine(_ line: String) -> some View {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      Spacer().frame(height: 4)
    } else if trimmed.hasPrefix("### ") {
      Text(inlineMarkdown(String(trimmed.dropFirst(4))))
        .font(.title3.bold())
        .padding(.top, 8)
        .textSelection(.enabled)
    } else if trimmed.hasPrefix("## ") {
      Text(inlineMarkdown(String(trimmed.dropFirst(3))))
        .font(.title2.bold())
        .padding(.top, 10)
        .textSelection(.enabled)
    } else if trimmed.hasPrefix("# ") {
      Text(inlineMarkdown(String(trimmed.dropFirst(2))))
        .font(.title.bold())
        .padding(.top, 12)
        .textSelection(.enabled)
    } else if trimmed.hasPrefix("> ") {
      Text(inlineMarkdown(String(trimmed.dropFirst(2))))
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 3)
        }
        .textSelection(.enabled)
    } else if let checkbox = checkboxLine(trimmed) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: checkbox.done ? "checkmark.square" : "square")
        Text(inlineMarkdown(checkbox.text))
          .font(.body)
          .textSelection(.enabled)
      }
    } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
      HStack(alignment: .top, spacing: 8) {
        Text("•")
        Text(inlineMarkdown(String(trimmed.dropFirst(2))))
          .font(.body)
          .textSelection(.enabled)
      }
      .padding(.leading, 4)
    } else if let ordered = orderedListLine(trimmed) {
      HStack(alignment: .top, spacing: 8) {
        Text("\(ordered.index).")
          .monospacedDigit()
        Text(inlineMarkdown(ordered.text))
          .font(.body)
          .textSelection(.enabled)
      }
      .padding(.leading, 4)
    } else if let seek = MinutesMarkdownDocument.chapterSeek(from: trimmed) {
      Button {
        onChapterSeek?(seek.seconds)
      } label: {
        HStack(alignment: .top, spacing: 8) {
          Text(seek.timestamp)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.tint)
          Text(inlineMarkdown(seek.title))
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("minutes.detail.chapter.seek")
    } else if trimmed.hasPrefix("```") {
      EmptyView()
    } else {
      Text(inlineMarkdown(line))
        .font(.body)
        .textSelection(.enabled)
    }
  }

  private func checkboxLine(_ trimmed: String) -> (done: Bool, text: String)? {
    if trimmed.hasPrefix("- [ ] ") {
      return (false, String(trimmed.dropFirst(6)))
    }
    if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
      return (true, String(trimmed.dropFirst(6)))
    }
    return nil
  }

  private func orderedListLine(_ trimmed: String) -> (index: Int, text: String)? {
    guard let dot = trimmed.firstIndex(of: ".") else { return nil }
    let number = trimmed[..<dot]
    guard let value = Int(number), value > 0 else { return nil }
    let rest = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    guard !rest.isEmpty else { return nil }
    return (value, rest)
  }

  private func inlineMarkdown(_ text: String) -> AttributedString {
    if let attributed = try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
      )
    ) {
      return attributed
    }
    return AttributedString(text)
  }
}
