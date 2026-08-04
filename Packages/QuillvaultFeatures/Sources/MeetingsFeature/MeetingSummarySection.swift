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
/// Block parser covers headings, lists, quotes, tasks, code fences, GFM tables (#45).
struct MinutesMarkdownView: View {
  let markdown: String
  var onChapterSeek: ((Double) -> Void)?

  var body: some View {
    let blocks = MinutesMarkdownDocument.blocks(from: markdown)
    VStack(alignment: .leading, spacing: 16) {
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("minutes.detail.markdown")
  }

  @ViewBuilder
  private func styledMarkdownBlock(_ text: String) -> some View {
    let lines = MinutesMarkdownLineParser.lines(from: text)
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        render(line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func render(_ line: MinutesMarkdownLine) -> some View {
    switch line {
    case .blank:
      Spacer().frame(height: 4)
    case .heading(let level, let text):
      Text(inlineMarkdown(text))
        .font(headingFont(level))
        .padding(.top, level == 1 ? 12 : 8)
        .textSelection(.enabled)
        .accessibilityIdentifier("minutes.detail.markdown.heading")
    case .quote(let text):
      Text(inlineMarkdown(text))
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 3)
        }
        .textSelection(.enabled)
    case .task(let done, let text):
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: done ? "checkmark.square" : "square")
        Text(inlineMarkdown(text))
          .font(.body)
          .textSelection(.enabled)
      }
    case .bullet(let text):
      HStack(alignment: .top, spacing: 8) {
        Text("•")
        Text(inlineMarkdown(text))
          .font(.body)
          .textSelection(.enabled)
      }
      .padding(.leading, 4)
    case .ordered(let index, let text):
      HStack(alignment: .top, spacing: 8) {
        Text("\(index).")
          .monospacedDigit()
        Text(inlineMarkdown(text))
          .font(.body)
          .textSelection(.enabled)
      }
      .padding(.leading, 4)
    case .chapterSeek(let seconds, let timestamp, let title):
      Button {
        onChapterSeek?(seconds)
      } label: {
        HStack(alignment: .top, spacing: 8) {
          Text(timestamp)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.tint)
          Text(inlineMarkdown(title))
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("minutes.detail.chapter.seek")
    case .code(let source):
      Text(source)
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("minutes.detail.markdown.code")
    case .table(let rows):
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, cells in
          HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
              Text(inlineMarkdown(cell))
                .font(rowIndex == 0 ? .subheadline.bold() : .subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
          }
          .background(
            rowIndex == 0
              ? Color.secondary.opacity(0.16)
              : Color.secondary.opacity(rowIndex.isMultiple(of: 2) ? 0.06 : 0.0)
          )
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
      )
      .accessibilityIdentifier("minutes.detail.markdown.table")
    case .paragraph(let text):
      Text(inlineMarkdown(text))
        .font(.body)
        .textSelection(.enabled)
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title.bold()
    case 2: return .title2.bold()
    default: return .title3.bold()
    }
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
