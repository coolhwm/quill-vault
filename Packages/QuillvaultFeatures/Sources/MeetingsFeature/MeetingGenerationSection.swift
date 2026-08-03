import Domain
import SwiftUI

public struct MeetingGenerationSection: View {
  let minutes: MeetingMarkdownAsset
  let snapshot: GenerationSnapshot?
  let isBusy: Bool
  let hasError: Bool
  let start: () -> Void
  let resume: () -> Void
  let cancel: () -> Void

  public init(
    minutes: MeetingMarkdownAsset,
    snapshot: GenerationSnapshot?,
    isBusy: Bool,
    hasError: Bool,
    start: @escaping () -> Void,
    resume: @escaping () -> Void,
    cancel: @escaping () -> Void
  ) {
    self.minutes = minutes
    self.snapshot = snapshot
    self.isBusy = isBusy
    self.hasError = hasError
    self.start = start
    self.resume = resume
    self.cancel = cancel
  }

  @ViewBuilder
  public var body: some View {
    if case .available = minutes {
      EmptyView()
    } else {
      GroupBox {
        content
      } label: {
        Label("minutes.generation.title", systemImage: "sparkles")
      }
      .accessibilityIdentifier("minutes.generation.section")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch minutes {
    case .available:
      EmptyView()
    case .missing, .downloadRequired, .unreadable:
      if isBusy {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            ProgressView()
            Text("minutes.generation.running")
              .font(.headline)
            Spacer()
            if let snapshot {
              Text("\(snapshot.job.progress)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
          if let snapshot {
            ProgressView(value: Double(snapshot.job.progress), total: 100)
          } else {
            ProgressView()
          }
          Button("minutes.generation.cancel", role: .cancel, action: cancel)
        }
      } else if let snapshot, snapshot.job.state == .paused {
        VStack(alignment: .leading, spacing: 12) {
          Label(
            "minutes.generation.paused",
            systemImage: "pause.circle"
          )
          .font(.headline)
          Text("minutes.generation.paused.description")
            .foregroundStyle(.secondary)
          if hasError {
            Text("minutes.generation.retryable")
              .foregroundStyle(.secondary)
          }
          Button("minutes.generation.resume", action: resume)
            .buttonStyle(.borderedProminent)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("minutes.generation.pending")
            .foregroundStyle(.secondary)
          Button("minutes.generation.start", action: start)
            .buttonStyle(.borderedProminent)
        }
      }
    }
  }
}
