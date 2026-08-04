import Application
import Domain
import SwiftUI

struct ModelProfileEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedPresetID: String
  @State private var name: String
  @State private var baseURL: String
  @State private var modelName: String
  @State private var apiKey = ""
  @State private var usesStreaming: Bool
  @State private var isSaving = false
  @State private var saveErrorMessage: String?
  @State private var recommendedModels: [String] = []
  @State private var isRefreshingModels = false
  @State private var refreshModelsMessage: String?

  private let profile: ModelProfile?
  private let onSave: (ModelProfileDraft) async throws -> Void
  private let presets = ModelProviderCatalog.all

  init(
    profile: ModelProfile?,
    onSave: @escaping (ModelProfileDraft) async throws -> Void
  ) {
    self.profile = profile
    self.onSave = onSave
    let matched = profile.flatMap {
      ModelProviderCatalog.matchingPreset(baseURL: $0.baseURL)
    }
    _selectedPresetID = State(
      initialValue: matched?.id ?? ModelProviderCatalog.customID
    )
    _name = State(initialValue: profile?.name ?? matched?.displayName ?? "")
    _baseURL = State(
      initialValue: profile?.baseURL.absoluteString
        ?? matched?.defaultBaseURL.absoluteString
        ?? "https://"
    )
    _modelName = State(
      initialValue: profile?.model ?? matched?.recommendedModels.first ?? ""
    )
    _usesStreaming = State(
      initialValue: profile?.parameters.usesStreaming
        ?? matched?.supportsStreaming
        ?? true
    )
    _recommendedModels = State(
      initialValue: matched?.recommendedModels ?? []
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("settings.models.editor.provider") {
          Picker("settings.models.editor.provider", selection: $selectedPresetID) {
            Text("settings.models.editor.provider.custom")
              .tag(ModelProviderCatalog.customID)
            ForEach(presets) { preset in
              Text(preset.displayName).tag(preset.id)
            }
          }
          .accessibilityIdentifier("settings.models.editor.provider")
          .onChange(of: selectedPresetID) { _, newValue in
            applyPreset(id: newValue)
          }
          if let preset = ModelProviderCatalog.preset(id: selectedPresetID) {
            Text(preset.configurationHint)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
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
            if !recommendedModels.isEmpty {
              Picker("settings.models.editor.model", selection: $modelName) {
                ForEach(recommendedModels, id: \.self) { model in
                  Text(model).tag(model)
                }
                if !recommendedModels.contains(modelName), !modelName.isEmpty {
                  Text(modelName).tag(modelName)
                }
              }
              .accessibilityIdentifier("settings.models.editor.model.preset")
            }
            TextField("settings.models.editor.model", text: $modelName)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .accessibilityIdentifier("settings.models.editor.model")
            Button {
              Task {
                await refreshRecommendedModels()
              }
            } label: {
              if isRefreshingModels {
                ProgressView()
              } else {
                Label(
                  "settings.models.editor.refresh_models",
                  systemImage: "arrow.clockwise"
                )
              }
            }
            .disabled(isRefreshingModels || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("settings.models.editor.refresh_models")
            if let refreshModelsMessage {
              Text(refreshModelsMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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

  private func applyPreset(id: String) {
    guard let preset = ModelProviderCatalog.preset(id: id) else {
      recommendedModels = []
      return
    }
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || presets.contains(where: { $0.displayName == name })
    {
      name = preset.displayName
    }
    baseURL = preset.defaultBaseURL.absoluteString
    recommendedModels = preset.recommendedModels
    if let first = preset.recommendedModels.first {
      modelName = first
    }
    usesStreaming = preset.supportsStreaming
    refreshModelsMessage = nil
  }

  @MainActor
  private func refreshRecommendedModels() async {
    guard !isRefreshingModels else {
      return
    }
    isRefreshingModels = true
    refreshModelsMessage = nil
    defer { isRefreshingModels = false }

    let builtIn = ModelProviderCatalog.builtInModels(for: selectedPresetID)
    guard
      let chatURL = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      let modelsURL = ModelProviderCatalog.modelsListURL(fromChatCompletionsURL: chatURL)
    else {
      recommendedModels = builtIn
      refreshModelsMessage = String(localized: "settings.models.editor.refresh_models.failed")
      return
    }

    var request = URLRequest(url: modelsURL)
    request.httpMethod = "GET"
    request.setValue(
      "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
      forHTTPHeaderField: "Authorization"
    )
    request.timeoutInterval = 20
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        recommendedModels = builtIn
        refreshModelsMessage = String(localized: "settings.models.editor.refresh_models.failed")
        return
      }
      let remote = ModelProviderCatalog.parseModelsListJSON(data)
      let merged = ModelProviderCatalog.mergeRecommended(builtIn: builtIn, remote: remote)
      recommendedModels = merged
      if modelName.isEmpty, let first = merged.first {
        modelName = first
      }
      refreshModelsMessage = String(localized: "settings.models.editor.refresh_models.success")
    } catch {
      recommendedModels = builtIn
      refreshModelsMessage = String(localized: "settings.models.editor.refresh_models.failed")
    }
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
    if let baseURLError = ModelProfileValidation.baseURLError(for: url) {
      saveErrorMessage = message(for: baseURLError)
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
