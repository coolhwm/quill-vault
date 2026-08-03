import Domain
import SwiftUI

struct MeetingDiagramSection: View {
  let minutes: MeetingMarkdownAsset

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
          ForEach(content.diagrams) { diagram in
            VStack(alignment: .leading, spacing: 8) {
              if let title = diagram.title, !title.isEmpty {
                Text(title)
                  .font(.headline)
              }
              MermaidDiagramView(source: diagram.source)
            }
            .accessibilityIdentifier("minutes.detail.diagram.\(diagram.id)")
          }
        }
      case .missing, .downloadRequired, .unreadable:
        Text("minutes.detail.diagram.pending")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("minutes.detail.diagram.section")
  }
}
