import Application
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
  @Bindable private var model: SettingsModel
  @State private var isDirectoryImporterPresented = false

  public init(model: SettingsModel) {
    self.model = model
  }

  public var body: some View {
    List {
      Section("settings.directory.section") {
        directoryRow
        Button("settings.directory.choose", systemImage: "folder.badge.plus") {
          isDirectoryImporterPresented = true
        }
        .accessibilityIdentifier("settings.directory.choose")
      }

      Section("settings.about.section") {
        Label("settings.local.first", systemImage: "iphone.and.arrow.forward")
        Label("settings.privacy", systemImage: "hand.raised")
      }
    }
    .navigationTitle("settings.navigation.title")
    .accessibilityIdentifier("settings.screen")
    .fileImporter(
      isPresented: $isDirectoryImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        return
      }
      Task {
        await model.selectDirectory(opaqueReference: url.absoluteString)
      }
    }
    .task {
      await model.load()
    }
  }

  @ViewBuilder
  private var directoryRow: some View {
    switch model.directoryState {
    case .checking:
      Label("settings.directory.checking", systemImage: "folder")
        .foregroundStyle(.secondary)
    case .recoveryRequired(let recovery):
      Label(
        recovery.settingsStatusKey,
        systemImage: "exclamationmark.folder"
      )
      .foregroundStyle(.orange)
    case .authorized(let directory):
      LabeledContent("settings.directory.current") {
        Text(directory.displayName)
      }
    }
  }
}

extension AuthoritativeDirectoryRecovery {
  fileprivate var settingsStatusKey: LocalizedStringKey {
    switch self {
    case .chooseDirectory:
      "settings.directory.required"
    case .renewAccess:
      "settings.directory.access.expired"
    case .downloadRequired:
      "settings.directory.download.required"
    case .tryAgain:
      "settings.directory.unavailable"
    }
  }
}
