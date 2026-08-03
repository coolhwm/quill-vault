import Domain
import SwiftUI

struct ModelProfilesSection: View {
  @Bindable var model: SettingsModel
  @State private var editor: ModelProfileEditor?
  @State private var testRequest: ModelProfile?
  @State private var deleteRequest: ModelProfileDeleteRequest?
  @State private var automaticGenerationRequest = false

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
      Toggle(
        "settings.models.automatic",
        isOn: Binding(
          get: { model.automaticGeneration.isEnabled },
          set: { updateAutomaticGeneration($0) }
        )
      )
      .disabled(currentUsableProfile == nil)
      if currentUsableProfile == nil {
        Text("settings.models.automatic.requires_verified")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if model.automaticGeneration.isEnabled {
        Text("settings.models.automatic.enabled")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
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
    .alert(
      "settings.models.automatic.confirm.title",
      isPresented: $automaticGenerationRequest
    ) {
      Button("settings.models.automatic.confirm.action") {
        Task {
          await model.setAutomaticGeneration(
            enabled: true,
            disclosureAcknowledged: true
          )
        }
      }
      Button("common.cancel", role: .cancel) {}
    } message: {
      Text(automaticGenerationDisclosure)
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

  private var automaticGenerationDisclosure: String {
    let destination =
      currentUsableProfile?.baseURL.host
      ?? currentUsableProfile?.baseURL.absoluteString
      ?? ""
    return
      destination + "\n"
      + String(localized: "settings.models.automatic.disclosure")
  }

  private func updateAutomaticGeneration(_ enabled: Bool) {
    if enabled,
      !model.automaticGeneration.disclosureAcknowledged
    {
      automaticGenerationRequest = true
      return
    }
    Task {
      await model.setAutomaticGeneration(
        enabled: enabled,
        disclosureAcknowledged: false
      )
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
