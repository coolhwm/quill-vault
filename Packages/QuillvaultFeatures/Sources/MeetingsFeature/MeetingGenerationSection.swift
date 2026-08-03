import Domain
import SwiftUI

public struct MeetingGenerationSection: View {
  let minutes: MeetingMarkdownAsset
  let snapshot: GenerationSnapshot?
  let isBusy: Bool
  let hasError: Bool
  let isMinutesExpired: Bool
  let modelProfiles: [ModelProfile]
  let selectedModelProfileID: ModelProfileID?
  let start: () -> Void
  let resume: () -> Void
  let cancel: () -> Void
  let regenerate: () -> Void
  let selectModelProfile: (ModelProfileID) -> Void

  public init(
    minutes: MeetingMarkdownAsset,
    snapshot: GenerationSnapshot?,
    isBusy: Bool,
    hasError: Bool,
    isMinutesExpired: Bool,
    modelProfiles: [ModelProfile] = [],
    selectedModelProfileID: ModelProfileID? = nil,
    start: @escaping () -> Void,
    resume: @escaping () -> Void,
    cancel: @escaping () -> Void,
    regenerate: @escaping () -> Void,
    selectModelProfile: @escaping (ModelProfileID) -> Void = { _ in }
  ) {
    self.minutes = minutes
    self.snapshot = snapshot
    self.isBusy = isBusy
    self.hasError = hasError
    self.isMinutesExpired = isMinutesExpired
    self.modelProfiles = modelProfiles
    self.selectedModelProfileID = selectedModelProfileID
    self.start = start
    self.resume = resume
    self.cancel = cancel
    self.regenerate = regenerate
    self.selectModelProfile = selectModelProfile
  }

  @ViewBuilder
  public var body: some View {
    GroupBox {
      content
    } label: {
      Label("minutes.generation.title", systemImage: "sparkles")
    }
    .accessibilityIdentifier("minutes.generation.section")
  }

  @ViewBuilder
  private var content: some View {
    if modelProfiles.count > 1 {
      Menu {
        ForEach(modelProfiles, id: \.id) { profile in
          Button {
            selectModelProfile(profile.id)
          } label: {
            if profile.id == selectedModelProfileID {
              Label(profile.name, systemImage: "checkmark")
            } else {
              Text(profile.name)
            }
          }
        }
      } label: {
        Label("minutes.generation.model", systemImage: "cpu")
      }
    }
    if isBusy || snapshot?.job.state == .running {
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
          Text(
            "minutes.generation.progress \(snapshot.job.completedChunkCount) \(snapshot.job.chunkCount)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          ProgressView()
        }
        Button("minutes.generation.cancel", role: .cancel, action: cancel)
      }
    } else if let snapshot, snapshot.job.state == .paused {
      VStack(alignment: .leading, spacing: 12) {
        if snapshot.job.pauseReason == .externalMinutesChanged {
          Label(
            "minutes.generation.expired",
            systemImage: "exclamationmark.triangle"
          )
          .font(.headline)
          Text("minutes.generation.replace.description")
            .foregroundStyle(.secondary)
          Button("minutes.generation.regenerate", action: regenerate)
            .buttonStyle(.borderedProminent)
        } else {
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
          Button("minutes.generation.regenerate", action: regenerate)
            .buttonStyle(.bordered)
        }
      }
    } else if snapshot?.job.state == .pending {
      VStack(alignment: .leading, spacing: 12) {
        Text("minutes.generation.queued")
          .foregroundStyle(.secondary)
        Button("minutes.generation.regenerate", action: regenerate)
          .buttonStyle(.bordered)
      }
    } else {
      switch minutes {
      case .available:
        VStack(alignment: .leading, spacing: 12) {
          if isMinutesExpired {
            Label(
              "minutes.generation.expired",
              systemImage: "exclamationmark.triangle"
            )
            .font(.headline)
            Text("minutes.generation.expired.description")
              .foregroundStyle(.secondary)
          } else {
            Text("minutes.generation.regenerate.description")
              .foregroundStyle(.secondary)
          }
          Button("minutes.generation.regenerate", action: regenerate)
            .buttonStyle(.borderedProminent)
        }
      case .missing, .downloadRequired, .unreadable:
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
