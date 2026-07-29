import DesignSystem
import Domain
import SwiftUI

struct RecordingFailureCard: View {
  let error: RecordingError
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: QuillvaultSpacing.standard) {
      Label(
        "recording.failure.title",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.headline)
      .foregroundStyle(.red)
      Text(messageKey)
        .foregroundStyle(.secondary)
      Button("recording.retry", action: retry)
        .buttonStyle(.bordered)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 20))
  }

  private var messageKey: LocalizedStringKey {
    switch error {
    case .microphonePermissionDenied:
      "recording.failure.permission"
    case .insufficientStorage:
      "recording.failure.storage"
    case .authoritativeDirectoryUnavailable:
      "recording.failure.directory"
    case .alreadyRecording:
      "recording.failure.already"
    case .invalidRecordedAudio:
      "recording.failure.invalid"
    case .recordingConsentRequired:
      "recording.notice.message"
    case .captureCouldNotStart, .recordingWriteFailed,
      .statePersistenceFailed, .noActiveRecording:
      "recording.failure.generic"
    }
  }
}
