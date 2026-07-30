import Domain
import SwiftUI

struct MeetingDiagramSection: View {
  let minutes: MeetingMarkdownAsset

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("minutes.detail.diagram", systemImage: "point.3.connected.trianglepath.dotted")
        .font(.title2.bold())
      if case .available(let content) = minutes,
        let diagram = content.diagramSource
      {
        ScrollView(.horizontal) {
          Text(diagram)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .padding()
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
      } else {
        Text("minutes.detail.diagram.pending")
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("minutes.detail.diagram.section")
  }

}
