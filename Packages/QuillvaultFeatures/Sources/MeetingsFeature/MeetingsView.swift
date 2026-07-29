import DesignSystem
import SwiftUI

public struct MeetingsView: View {
  public init() {}

  public var body: some View {
    QuillvaultEmptyState(
      "minutes.empty.title",
      systemImage: "doc.text",
      description: "minutes.empty.description"
    )
    .navigationTitle("minutes.navigation.title")
    .accessibilityIdentifier("minutes.screen")
  }
}
