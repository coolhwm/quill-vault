import Application
import DesignSystem
import Domain
import SwiftUI
import UniformTypeIdentifiers

public struct MeetingsView: View {
  @Environment(\.scenePhase) private var scenePhase
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
    .navigationDestination(
      isPresented: Binding(
        get: { model.detailMeeting != nil },
        set: { presented in
          if !presented {
            model.clearDetailRoute()
          }
        }
      )
    ) {
      if let meeting = model.detailMeeting,
        case .loaded(let snapshot) = model.state
      {
        MeetingDetailView(
          model: model.makeDetailModel(
            directory: snapshot.directory,
            meeting: meeting
          )
        )
      }
    }
    .navigationTitle("minutes.navigation.title")
    .toolbar {
      ToolbarItem(placement: .secondaryAction) {
        filterMenu
      }
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
    .task {
      // Keep list generation progress aligned with home/detail.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        await model.refreshProcessingProjection()
      }
    }
    .searchable(
      text: $model.searchText,
      placement: .automatic,
      prompt: "minutes.search.prompt"
    )
    .task(id: model.searchSelection) {
      guard model.state != .idle, model.state != .loading else {
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else {
        return
      }
      await model.applySearch()
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else {
        return
      }
      await model.synchronizeUntilCancelled()
    }
    .accessibilityIdentifier("minutes.screen")
  }

  @ViewBuilder
  private func loadedContent(
    _ snapshot: Application.MeetingLibrarySnapshot
  ) -> some View {
    if snapshot.meetings.isEmpty {
      if model.hasActiveSearch {
        ContentUnavailableView {
          Label("minutes.search.empty.title", systemImage: "magnifyingglass")
        } description: {
          Text("minutes.search.empty.description")
        } actions: {
          Button("minutes.search.clear") {
            model.clearFilters()
          }
        }
      } else {
        QuillvaultEmptyState(
          "minutes.empty.title",
          systemImage: "doc.text",
          description: "minutes.empty.description"
        )
      }
    } else {
      List {
        Section {
          ForEach(snapshot.meetings, id: \.id) { meeting in
            VStack(alignment: .leading, spacing: 8) {
              NavigationLink {
                MeetingDetailView(
                  model: model.makeDetailModel(
                    directory: snapshot.directory,
                    meeting: meeting
                  )
                )
              } label: {
                MeetingCardView(
                  meeting: meeting,
                  processingPhase: model.processingPhase(for: meeting.id)
                )
              }
              if meeting.assets == [.recording] {
                Button {
                  Task {
                    await model.retryTranscript(meetingID: meeting.id)
                  }
                } label: {
                  if model.recoveringMeetingID == meeting.id {
                    ProgressView()
                  } else {
                    Label(
                      "minutes.asset.transcript.retry",
                      systemImage: "arrow.clockwise"
                    )
                  }
                }
                .disabled(model.recoveringMeetingID != nil)
              }
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

  private var filterMenu: some View {
    Menu {
      Menu("minutes.filter.date") {
        ForEach(MeetingDateFilter.allCases, id: \.self) { filter in
          Button {
            model.dateFilter = filter
          } label: {
            if model.dateFilter == filter {
              Label(filter.titleKey, systemImage: "checkmark")
            } else {
              Text(filter.titleKey)
            }
          }
        }
      }
      Menu("minutes.filter.status") {
        ForEach(MeetingIndexStatus.allCases, id: \.self) { status in
          Button {
            model.toggleStatus(status)
          } label: {
            if model.selectedStatuses.contains(status) {
              Label(status.titleKey, systemImage: "checkmark")
            } else {
              Text(status.titleKey)
            }
          }
        }
      }
      if !model.availableModelNames.isEmpty {
        Menu("minutes.filter.model") {
          Button {
            model.selectedModelName = nil
          } label: {
            if model.selectedModelName == nil {
              Label("minutes.filter.all.models", systemImage: "checkmark")
            } else {
              Text("minutes.filter.all.models")
            }
          }
          ForEach(model.availableModelNames, id: \.self) { name in
            Button {
              model.selectedModelName = name
            } label: {
              if model.selectedModelName == name {
                Label(name, systemImage: "checkmark")
              } else {
                Text(name)
              }
            }
          }
        }
      }
      if model.hasActiveSearch {
        Divider()
        Button("minutes.search.clear", role: .destructive) {
          model.clearFilters()
        }
      }
    } label: {
      Label("minutes.filter", systemImage: "line.3.horizontal.decrease.circle")
    }
    .accessibilityIdentifier("minutes.filter")
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

}

extension MeetingDateFilter {
  fileprivate var titleKey: LocalizedStringKey {
    switch self {
    case .all:
      "minutes.filter.date.all"
    case .today:
      "minutes.filter.date.today"
    case .lastSevenDays:
      "minutes.filter.date.seven"
    case .lastThirtyDays:
      "minutes.filter.date.thirty"
    }
  }
}

extension MeetingIndexStatus {
  fileprivate var titleKey: LocalizedStringKey {
    switch self {
    case .awaitingTranscript:
      "minutes.status.awaiting.transcript"
    case .awaitingMinutes:
      "minutes.status.awaiting.minutes"
    case .minutesCompleted:
      "minutes.status.completed"
    case .minutesExpired:
      "minutes.status.expired"
    }
  }
}

extension MeetingLibraryRecovery {
  fileprivate var titleKey: LocalizedStringKey {
    switch self {
    case .chooseDirectory:
      "minutes.recovery.directory.title"
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
      "minutes.recovery.directory.description"
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
