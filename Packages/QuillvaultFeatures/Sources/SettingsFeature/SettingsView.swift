import Application
import DesignSystem
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
  @Bindable private var model: SettingsModel
  @State private var isDirectoryImporterPresented = false
  @State private var isDiagnosticsExporterPresented = false
  @State private var isDiagnosticsExportErrorPresented = false
  @State private var diagnosticDocument = DiagnosticExportDocument()

  public init(model: SettingsModel) {
    self.model = model
  }

  public var body: some View {
    List {
      ModelProfilesSection(model: model)

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

      Section("settings.diagnostics.section") {
        if model.diagnosticsUnavailable {
          Label("settings.diagnostics.unavailable", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        } else {
          Label {
            VStack(alignment: .leading, spacing: 4) {
              Text("settings.diagnostics.count \(model.diagnosticPreview.eventCount)")
              Text("settings.diagnostics.retention \(model.diagnosticPreview.retentionDays)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "waveform.path.ecg")
          }
        }
        Text("settings.diagnostics.description")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("settings.diagnostics.export", systemImage: "square.and.arrow.up") {
          Task {
            do {
              let export = try await model.exportDiagnostics()
              diagnosticDocument = DiagnosticExportDocument(data: export.data)
              isDiagnosticsExporterPresented = true
            } catch {
              isDiagnosticsExportErrorPresented = true
            }
          }
        }
        .disabled(model.diagnosticsUnavailable)
        .accessibilityIdentifier("settings.diagnostics.export")
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
    .fileExporter(
      isPresented: $isDiagnosticsExporterPresented,
      document: diagnosticDocument,
      contentType: .json,
      defaultFilename: "quillvault-diagnostics"
    ) { _ in }
    .alert(
      "settings.diagnostics.export_failed",
      isPresented: $isDiagnosticsExportErrorPresented
    ) {
      Button("common.ok", role: .cancel) {}
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
