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
  @State private var saveErrorMessage: String?

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
              .autocorrectionDisabled(true)
              .keyboardType(.URL)
              .accessibilityIdentifier("settings.models.editor.base_url")
            Text("settings.models.editor.base_url_hint")
              .font(.footnote)
              .foregroundStyle(.secondary)
            TextField("settings.models.editor.model", text: $modelName)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .accessibilityIdentifier("settings.models.editor.model")
          #else
            TextField("settings.models.editor.base_url", text: $baseURL)
              .autocorrectionDisabled(true)
              .accessibilityIdentifier("settings.models.editor.base_url")
            Text("settings.models.editor.base_url_hint")
              .font(.footnote)
              .foregroundStyle(.secondary)
            TextField("settings.models.editor.model", text: $modelName)
              .autocorrectionDisabled(true)
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
              .autocorrectionDisabled(true)
              .accessibilityIdentifier("settings.models.editor.api_key")
          #else
            SecureField("settings.models.editor.api_key", text: $apiKey)
              .autocorrectionDisabled(true)
              .accessibilityIdentifier("settings.models.editor.api_key")
          #endif
          if profile != nil {
            Text("settings.models.editor.key_saved")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        if let saveErrorMessage {
          Text(saveErrorMessage)
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
          .disabled(isSaving)
          .accessibilityIdentifier("settings.models.editor.save")
        }
      }
    }
  }

  private var navigationTitle: LocalizedStringKey {
    profile == nil
      ? "settings.models.editor.add.title"
      : "settings.models.editor.edit.title"
  }

  private func save() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      saveErrorMessage = String(localized: "settings.models.editor.invalid_name")
      return
    }
    let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL) else {
      saveErrorMessage = String(localized: "settings.models.editor.invalid_url")
      return
    }
    let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedModel.isEmpty else {
      saveErrorMessage = String(localized: "settings.models.editor.invalid_model")
      return
    }
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if profile == nil && trimmedAPIKey.isEmpty {
      saveErrorMessage = String(localized: "settings.models.editor.missing_credential")
      return
    }
    isSaving = true
    saveErrorMessage = nil
    Task {
      do {
        try await onSave(
          ModelProfileDraft(
            id: profile?.id,
            name: trimmedName,
            baseURL: url,
            model: trimmedModel,
            parameters: ModelGenerationParameters(
              temperature: profile?.parameters.temperature ?? 0.2,
              maximumOutputTokens:
                profile?.parameters.maximumOutputTokens ?? 4_096,
              usesStreaming: usesStreaming
            ),
            credentialReference: profile?.credentialReference,
            apiKey: trimmedAPIKey.isEmpty ? nil : trimmedAPIKey
          )
        )
        dismiss()
      } catch {
        isSaving = false
        saveErrorMessage = message(for: error)
      }
    }
  }

  private func message(for error: Error) -> String {
    switch error {
    case ModelProfileWorkflowError.invalidName:
      String(localized: "settings.models.editor.invalid_name")
    case ModelProfileWorkflowError.invalidBaseURL:
      String(localized: "settings.models.editor.invalid_url")
    case ModelProfileWorkflowError.invalidEndpoint:
      String(localized: "settings.models.editor.invalid_endpoint")
    case ModelProfileWorkflowError.invalidModel:
      String(localized: "settings.models.editor.invalid_model")
    case ModelProfileWorkflowError.missingCredential:
      String(localized: "settings.models.editor.missing_credential")
    case ModelCredentialError.unavailableUntilFirstUnlock:
      String(localized: "settings.models.editor.keychain_locked")
    case ModelCredentialError.unavailable:
      String(localized: "settings.models.editor.keychain_unavailable")
    case ModelProfileStoreError.unavailable, ModelProfileStoreError.invalidData:
      String(localized: "settings.models.editor.storage_unavailable")
    default:
      String(localized: "settings.models.editor.save_failed")
    }
  }
}
