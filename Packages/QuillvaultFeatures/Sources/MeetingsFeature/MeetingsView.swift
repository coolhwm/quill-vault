import Application
import DesignSystem
import Domain
import SwiftUI
import UniformTypeIdentifiers

public struct MeetingsView: View {
  @Bindable private var model: MeetingsModel
  @State private var isDirectoryImporterPresented = false

  public init(model: MeetingsModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      switch model.state {
      case .idle, .loading:
        ProgressView("minutes.loading")
          .accessibilityIdentifier("minutes.loading")
      case .loaded(let snapshot):
        loadedContent(snapshot)
      case .failed(let recovery):
        recoveryContent(recovery)
      }
    }
    .navigationTitle("minutes.navigation.title")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("minutes.directory.choose", systemImage: "folder.badge.plus") {
          isDirectoryImporterPresented = true
        }
        .accessibilityIdentifier("minutes.directory.choose")
      }
    }
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
      guard model.state == .idle else {
        return
      }
      await model.load()
    }
    .accessibilityIdentifier("minutes.screen")
  }

  @ViewBuilder
  private func loadedContent(
    _ snapshot: Application.MeetingLibrarySnapshot
  ) -> some View {
    if snapshot.meetings.isEmpty {
      QuillvaultEmptyState(
        "minutes.empty.title",
        systemImage: "doc.text",
        description: "minutes.empty.description"
      )
    } else {
      List {
        Section {
          ForEach(snapshot.meetings, id: \.id) { meeting in
            VStack(alignment: .leading, spacing: 6) {
              Text(meeting.relativeDirectory)
                .font(.headline)
              Text(assetDescription(meeting.assets))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(
              "minutes.meeting.\(meeting.id.rawValue.uuidString)"
            )
          }
        } header: {
          Text(snapshot.directory.displayName)
        } footer: {
          if snapshot.diagnosticCount > 0 {
            Text(
              "minutes.diagnostics \(snapshot.diagnosticCount)"
            )
          }
        }
      }
      .refreshable {
        await model.rebuild()
      }
    }
  }

  private func recoveryContent(
    _ recovery: MeetingLibraryRecovery
  ) -> some View {
    ContentUnavailableView {
      Label(recovery.titleKey, systemImage: recovery.systemImage)
    } description: {
      Text(recovery.descriptionKey)
    } actions: {
      switch recovery {
      case .chooseDirectory, .renewAccess:
        Button("minutes.directory.choose") {
          isDirectoryImporterPresented = true
        }
      case .downloadRequired, .tryAgain:
        Button("minutes.retry") {
          Task {
            await model.rebuild()
          }
        }
      }
    }
  }

  private func assetDescription(
    _ assets: MeetingAssetPresence
  ) -> LocalizedStringKey {
    if assets.contains(.minutes) {
      return "minutes.asset.minutes"
    }
    if assets.contains(.transcript) {
      return "minutes.asset.transcript"
    }
    return "minutes.asset.recording"
  }
}

extension MeetingLibraryRecovery {
  fileprivate var titleKey: LocalizedStringKey {
    switch self {
    case .chooseDirectory:
      "minutes.recovery.icloud.title"
    case .renewAccess:
      "minutes.recovery.access.title"
    case .downloadRequired:
      "minutes.recovery.download.title"
    case .tryAgain:
      "minutes.recovery.generic.title"
    }
  }

  fileprivate var descriptionKey: LocalizedStringKey {
    switch self {
    case .chooseDirectory:
      "minutes.recovery.icloud.description"
    case .renewAccess:
      "minutes.recovery.access.description"
    case .downloadRequired:
      "minutes.recovery.download.description"
    case .tryAgain:
      "minutes.recovery.generic.description"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .chooseDirectory, .renewAccess:
      "folder.badge.questionmark"
    case .downloadRequired:
      "icloud.and.arrow.down"
    case .tryAgain:
      "arrow.clockwise"
    }
  }
}
