import Application
import Domain
import SwiftUI

struct ModelProfileEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var baseURL: String
  @State private var modelName: String
  @State private var apiKey = ""
  @State private var usesStreaming: Bool
  @State private var isSaving = false
  @State private var saveFailed = false

  private let profile: ModelProfile?
  private let onSave: (ModelProfileDraft) async throws -> Void

  init(
    profile: ModelProfile?,
    onSave: @escaping (ModelProfileDraft) async throws -> Void
  ) {
    self.profile = profile
    self.onSave = onSave
    _name = State(initialValue: profile?.name ?? "")
    _baseURL = State(
      initialValue: profile?.baseURL.absoluteString ?? "https://"
    )
    _modelName = State(initialValue: profile?.model ?? "")
    _usesStreaming = State(
      initialValue: profile?.parameters.usesStreaming ?? true
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("settings.models.editor.profile") {
          TextField("settings.models.editor.name", text: $name)
            .accessibilityIdentifier("settings.models.editor.name")
          #if os(iOS)
            TextField("settings.models.editor.base_url", text: $baseURL)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              .accessibilityIdentifier("settings.models.editor.base_url")
            TextField("settings.models.editor.model", text: $modelName)
              .textInputAutocapitalization(.never)
              .accessibilityIdentifier("settings.models.editor.model")
          #else
            TextField("settings.models.editor.base_url", text: $baseURL)
              .accessibilityIdentifier("settings.models.editor.base_url")
            TextField("settings.models.editor.model", text: $modelName)
              .accessibilityIdentifier("settings.models.editor.model")
          #endif
          Toggle(
            "settings.models.editor.streaming",
            isOn: $usesStreaming
          )
        }
        Section("settings.models.editor.credential") {
          #if os(iOS)
            SecureField("settings.models.editor.api_key", text: $apiKey)
              .textInputAutocapitalization(.never)
              .accessibilityIdentifier("settings.models.editor.api_key")
          #else
            SecureField("settings.models.editor.api_key", text: $apiKey)
              .accessibilityIdentifier("settings.models.editor.api_key")
          #endif
          if profile != nil {
            Text("settings.models.editor.key_saved")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        if saveFailed {
          Text("settings.models.editor.save_failed")
            .foregroundStyle(.red)
        }
      }
      .navigationTitle(navigationTitle)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("common.cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("common.save") {
            save()
          }
          .disabled(isSaving || !canSave)
          .accessibilityIdentifier("settings.models.editor.save")
        }
      }
    }
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && URL(string: baseURL)?.host != nil
      && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (profile != nil || !apiKey.isEmpty)
  }

  private var navigationTitle: LocalizedStringKey {
    profile == nil
      ? "settings.models.editor.add.title"
      : "settings.models.editor.edit.title"
  }

  private func save() {
    guard let url = URL(string: baseURL) else {
      saveFailed = true
      return
    }
    isSaving = true
    saveFailed = false
    Task {
      do {
        try await onSave(
          ModelProfileDraft(
            id: profile?.id,
            name: name,
            baseURL: url,
            model: modelName,
            parameters: ModelGenerationParameters(
              temperature: profile?.parameters.temperature ?? 0.2,
              maximumOutputTokens:
                profile?.parameters.maximumOutputTokens ?? 4_096,
              usesStreaming: usesStreaming
            ),
            credentialReference: profile?.credentialReference,
            apiKey: apiKey.isEmpty ? nil : apiKey
          )
        )
        dismiss()
      } catch {
        isSaving = false
        saveFailed = true
      }
    }
  }
}
