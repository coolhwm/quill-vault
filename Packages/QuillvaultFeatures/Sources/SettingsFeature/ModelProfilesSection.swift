import Domain
import SwiftUI

struct ModelProfilesSection: View {
  @Bindable var model: SettingsModel
  @State private var editor: ModelProfileEditor?
  @State private var testRequest: ModelProfile?
  @State private var deleteRequest: ModelProfileDeleteRequest?
  var body: some View {
    Section("settings.models.section") {
      if model.modelProfilesUnavailable {
        Label(
          "settings.models.unavailable",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.red)
      }
      if model.modelProfiles.isEmpty {
        Text("settings.models.empty")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.modelProfiles, id: \.id) { profile in
          profileRow(profile)
        }
      }
      Button("settings.models.add", systemImage: "plus") {
        editor = ModelProfileEditor(profile: nil)
      }
      .accessibilityIdentifier("settings.models.add")
      if model.automaticGeneration.isEnabled {
        Toggle(
          "settings.models.automatic",
          isOn: Binding(
            get: { true },
            set: { enabled in
              if !enabled {
                Task {
                  await model.setAutomaticGeneration(
                    enabled: false,
                    disclosureAcknowledged: true
                  )
                }
              }
            }
          )
        )
        .accessibilityIdentifier("settings.models.automatic")
      } else {
        // Use an explicit enable control so first-time disclosure always has a
        // reliable presentation path (Toggle Binding rejections are flaky under
        // XCTest and can swallow the confirmation alert).
        Button {
          model.requestAutomaticGenerationDisclosure()
        } label: {
          Label(
            "settings.models.automatic",
            systemImage: "sparkles"
          )
        }
        .disabled(currentUsableProfile == nil)
        .accessibilityIdentifier("settings.models.automatic")
      }
      if currentUsableProfile == nil {
        Text("settings.models.automatic.requires_verified")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if model.automaticGeneration.isEnabled {
        Text("settings.models.automatic.enabled")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Toggle(
        "settings.transcript.quality",
        isOn: Binding(
          get: { model.transcriptQuality.isEnabled },
          set: { enabled in
            Task {
              await model.setTranscriptQuality(enabled: enabled)
            }
          }
        )
      )
      .accessibilityIdentifier("settings.transcript.quality")
      Text("settings.transcript.quality.description")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .sheet(item: $editor) { editor in
      ModelProfileEditorView(profile: editor.profile) { draft in
        try await model.saveProfile(draft)
      }
    }
    .alert(
      "settings.models.test.confirm.title",
      isPresented: Binding(
        get: { testRequest != nil },
        set: { if !$0 { testRequest = nil } }
      ),
      presenting: testRequest
    ) { profile in
      Button("settings.models.test.confirm.action") {
        Task {
          await model.testProfile(profile.id)
        }
      }
      Button("common.cancel", role: .cancel) {}
    } message: { profile in
      Text(
        "\(profile.baseURL.host ?? profile.baseURL.absoluteString)\n"
          + String(localized: "settings.models.test.disclosure")
      )
    }
    .alert(item: $deleteRequest) { request in
      Alert(
        title: Text("settings.models.delete.title"),
        message: Text(request.message),
        primaryButton: .destructive(
          Text("settings.models.delete.action")
        ) {
          Task {
            await model.deleteProfile(
              request.profile.id,
              confirmed: true
            )
          }
        },
        secondaryButton: .cancel(Text("common.cancel"))
      )
    }
  }

  private func profileRow(_ profile: ModelProfile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button {
          Task {
            await model.selectProfile(profile.id)
          }
        } label: {
          Label {
            VStack(alignment: .leading) {
              Text(profile.name)
              Text(profile.model)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(
              systemName:
                model.currentModelProfileID == profile.id
                ? "checkmark.circle.fill"
                : "circle"
            )
          }
        }
        .buttonStyle(.plain)
        .disabled(!profile.isUsable)
        Spacer()
        Menu {
          Button("settings.models.test", systemImage: "network") {
            testRequest = profile
          }
          Button("settings.models.edit", systemImage: "pencil") {
            editor = ModelProfileEditor(profile: profile)
          }
          Button(
            "settings.models.delete",
            systemImage: "trash",
            role: .destructive
          ) {
            prepareDeletion(profile)
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("settings.models.actions")
      }
      testStatus(profile)
      if !profile.isUsable,
        model.profileTestState[profile.id] == nil
      {
        Label(
          "settings.models.unverified",
          systemImage: "exclamationmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier(
      "settings.models.profile.\(profile.id.rawValue.uuidString)"
    )
  }

  @ViewBuilder
  private func testStatus(_ profile: ModelProfile) -> some View {
    switch model.profileTestState[profile.id] {
    case .testing:
      ProgressView("settings.models.testing")
    case .succeeded(let domain):
      Label(
        "\(String(localized: "settings.models.test.succeeded")) \(domain)",
        systemImage: "checkmark.circle.fill"
      )
      .font(.caption)
      .foregroundStyle(.green)
    case .failed:
      Label(
        "settings.models.test.failed",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.caption)
      .foregroundStyle(.red)
    case nil:
      EmptyView()
    }
  }

  private func prepareDeletion(_ profile: ModelProfile) {
    Task {
      let impact = await model.deletionImpact(profile.id)
      let message: String
      switch impact {
      case .safe:
        message = String(localized: "settings.models.delete.safe")
      case .unfinishedTasks(let count):
        message =
          String(localized: "settings.models.delete.unfinished")
          + " \(count)"
      }
      deleteRequest = ModelProfileDeleteRequest(
        profile: profile,
        message: message
      )
    }
  }

  private var currentUsableProfile: ModelProfile? {
    model.modelProfiles.first {
      $0.id == model.currentModelProfileID && $0.isUsable
    }
  }

}

private struct ModelProfileEditor: Identifiable {
  let id = UUID()
  let profile: ModelProfile?
}

private struct ModelProfileDeleteRequest: Identifiable {
  let id = UUID()
  let profile: ModelProfile
  let message: String
}
