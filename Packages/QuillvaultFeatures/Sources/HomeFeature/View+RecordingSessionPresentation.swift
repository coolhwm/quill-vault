import SwiftUI

extension View {
  @ViewBuilder
  func recordingSessionPresentation(
    isPresented: Binding<Bool>,
    model: HomeRecordingModel
  ) -> some View {
    #if os(iOS)
      fullScreenCover(isPresented: isPresented) {
        RecordingSessionView(model: model)
          .interactiveDismissDisabled()
      }
    #else
      sheet(isPresented: isPresented) {
        RecordingSessionView(model: model)
          .interactiveDismissDisabled()
      }
    #endif
  }

  @ViewBuilder
  func recordingNavigationTitleStyle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}
