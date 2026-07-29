import SwiftUI

public struct QuillvaultEmptyState: View {
  private let title: LocalizedStringKey
  private let systemImage: String
  private let description: LocalizedStringKey

  public init(
    _ title: LocalizedStringKey,
    systemImage: String,
    description: LocalizedStringKey
  ) {
    self.title = title
    self.systemImage = systemImage
    self.description = description
  }

  public var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(description)
    }
    .padding(QuillvaultSpacing.standard)
  }
}
