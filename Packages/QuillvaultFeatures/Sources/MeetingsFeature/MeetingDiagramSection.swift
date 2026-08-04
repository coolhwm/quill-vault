import Domain
import SwiftUI

struct MeetingDiagramSection: View {
  let minutes: MeetingMarkdownAsset
  @State private var fullscreen: FullscreenDiagram?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("minutes.detail.diagram", systemImage: "point.3.connected.trianglepath.dotted")
        .font(.title2.bold())
      switch minutes {
      case .available(let content):
        if content.diagrams.isEmpty {
          if content.informationMayBeIncomplete {
            Text("minutes.detail.diagram.partial")
              .foregroundStyle(.secondary)
          } else {
            Text("minutes.detail.diagram.none")
              .foregroundStyle(.secondary)
          }
        } else {
          if content.informationMayBeIncomplete {
            Label(
              "minutes.detail.diagram.partial",
              systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          ForEach(Array(content.diagrams.enumerated()), id: \.element.id) { index, diagram in
            diagramCard(diagram, index: index)
          }
        }
      case .missing, .downloadRequired, .unreadable:
        Text("minutes.detail.diagram.pending")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("minutes.detail.diagram.section")
    .modifier(DiagramFullscreenPresenter(item: $fullscreen))
  }

  @ViewBuilder
  private func diagramCard(_ diagram: MeetingDiagram, index: Int) -> some View {
    let title = diagramDisplayTitle(diagram, index: index)
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
        .accessibilityIdentifier("minutes.detail.diagram.title.\(diagram.id)")
      MermaidDiagramView(source: diagram.source, preferredHeight: 220)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .contentShape(Rectangle())
        .onTapGesture {
          fullscreen = FullscreenDiagram(
            id: diagram.id,
            title: title,
            source: diagram.source
          )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("minutes.detail.diagram.fullscreen")
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("minutes.detail.diagram.\(diagram.id)")
  }

  private func diagramDisplayTitle(_ diagram: MeetingDiagram, index: Int) -> String {
    if let title = diagram.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }
    return String(format: String(localized: "minutes.detail.diagram.untitled"), index + 1)
  }
}

private struct FullscreenDiagram: Identifiable {
  let id: String
  let title: String
  let source: String
}

private struct DiagramFullscreenPresenter: ViewModifier {
  @Binding var item: FullscreenDiagram?

  func body(content: Content) -> some View {
    #if os(iOS)
      content.fullScreenCover(item: $item) { diagram in
        fullscreenContent(diagram)
      }
    #else
      content.sheet(item: $item) { diagram in
        fullscreenContent(diagram)
      }
    #endif
  }

  @ViewBuilder
  private func fullscreenContent(_ diagram: FullscreenDiagram) -> some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text(diagram.title)
          .font(.headline)
        MermaidDiagramView(source: diagram.source, preferredHeight: 480)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding()
      .navigationTitle("minutes.detail.diagram.fullscreen")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("minutes.detail.diagram.closeFullscreen") {
            item = nil
          }
          .accessibilityIdentifier("minutes.detail.diagram.closeFullscreen")
        }
      }
    }
  }
}
