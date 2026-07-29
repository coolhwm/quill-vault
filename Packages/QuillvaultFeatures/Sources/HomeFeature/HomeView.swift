import DesignSystem
import SwiftUI

public struct HomeView: View {
  public init() {}

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuillvaultSpacing.spacious) {
        VStack(alignment: .leading, spacing: QuillvaultSpacing.compact) {
          Text("Quillvault")
            .font(.largeTitle.bold())
          Text("home.subtitle")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        QuillvaultEmptyState(
          "home.empty.title",
          systemImage: "waveform",
          description: "home.empty.description"
        )
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
      }
      .padding(QuillvaultSpacing.standard)
    }
    .accessibilityIdentifier("home.screen")
  }
}
