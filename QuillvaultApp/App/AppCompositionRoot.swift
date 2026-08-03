import Application
import AudioCapture
import AudioPlayback
import Domain
import Foundation
import HomeFeature
import MeetingFileStore
import MeetingsFeature
import ModelServices
import Observation
import PersistenceGRDB
import SettingsFeature
import SpeechTranscription

@MainActor
@Observable
final class AppCompositionRoot {
  let router: AppRouter
  let recordingModel: HomeRecordingModel
  let meetingsModel: MeetingsModel
  let settingsModel: SettingsModel
  let lifecycleCoordinator: AppLifecycleCoordinator
  let actionButtonCoordinator: ActionButtonRecordingCoordinator
  let generationBackgroundCoordinator: GenerationBackgroundCoordinator

  init(
    router: AppRouter = AppRouter(),
    meetingLibrary: (any MeetingLibraryUseCase)? = nil,
    recording: (any RecordingUseCase)? = nil
  ) {
    self.router = router
    let fileStore = MeetingFileStore()
    let diagnostics = Self.makeDiagnostics()
    let resolvedMeetingLibrary =
      meetingLibrary ?? Self.makeDefaultMeetingLibrary(fileStore: fileStore)
    let resolvedMeetingDetail: any MeetingDetailUseCase =
      Self.isMeetingDetailUITest
      ? UITestMeetingDetailUseCase()
      : MeetingDetailWorkflow(access: fileStore)
    let directoryAuthorization = Self.makeDefaultDirectoryAuthorization(
      fileStore: fileStore
    )
    let resolvedRecording =
      recording
      ?? Self.makeDefaultRecording(
        fileStore: fileStore,
        diagnostics: diagnostics.recorder
      )
    let resolvedModelProfiles = Self.makeDefaultModelProfiles(
      diagnostics: diagnostics.recorder
    )
    let backgroundCoordinator = GenerationBackgroundCoordinator(
      diagnostics: diagnostics.recorder
    )
    let resolvedGeneration = Self.makeDefaultGeneration(
      fileStore: fileStore,
      modelProfiles: resolvedModelProfiles,
      diagnostics: diagnostics.recorder,
      onJobRegistered: { [weak backgroundCoordinator] job in
        await backgroundCoordinator?.schedule(jobID: job.id)
      }
    )
    backgroundCoordinator.configure(
      library: resolvedMeetingLibrary,
      generation: resolvedGeneration
    )
    let recordingQuickStart = RecordingQuickStartWorkflow(
      recording: resolvedRecording,
      directory: directoryAuthorization
    )
    recordingModel = HomeRecordingModel(
      recording: resolvedRecording,
      directory: directoryAuthorization,
      quickStart: recordingQuickStart
    )
    actionButtonCoordinator = ActionButtonRecordingCoordinator(
      router: router,
      recordingModel: recordingModel,
      quickStart: recordingQuickStart
    )
    lifecycleCoordinator = AppLifecycleCoordinator(
      recordingModel: recordingModel,
      generationBackgroundCoordinator: backgroundCoordinator
    )
    generationBackgroundCoordinator = backgroundCoordinator
    meetingsModel = MeetingsModel(
      library: resolvedMeetingLibrary,
      transcriptionRecovery: resolvedRecording,
      detail: resolvedMeetingDetail,
      makePlayer: {
        if Self.isMeetingDetailUITest {
          return UITestMeetingAudioPlayer()
        }
        return SystemMeetingAudioPlayer(
          access: MeetingAudioFileAccessAdapter(store: fileStore)
        )
      },
      generation: resolvedGeneration,
      modelProfiles: resolvedModelProfiles,
      cancelScheduledGeneration: { [weak backgroundCoordinator] jobID in
        await backgroundCoordinator?.cancelScheduledTask(jobID: jobID)
      }
    )
    settingsModel = SettingsModel(
      directory: directoryAuthorization,
      library: resolvedMeetingLibrary,
      modelProfiles: resolvedModelProfiles,
      diagnostics: diagnostics.useCase
    )
  }

  private static func makeMeetingLibrary(
    fileStore: MeetingFileStore
  ) -> any MeetingLibraryUseCase {
    RetryingMeetingLibraryUseCase {
      try buildMeetingLibrary(fileStore: fileStore)
    }
  }

  private static func makeDefaultMeetingLibrary(
    fileStore: MeetingFileStore
  ) -> any MeetingLibraryUseCase {
    if isMeetingDetailUITest {
      return UITestMeetingLibraryUseCase(
        snapshot: UITestMeetingDetailUseCase.librarySnapshot
      )
    }
    if isRecordingUITest {
      return UITestMeetingLibraryUseCase()
    }
    return makeMeetingLibrary(fileStore: fileStore)
  }

  private static func makeDefaultDirectoryAuthorization(
    fileStore: MeetingFileStore
  ) -> any AuthoritativeDirectoryUseCase {
    if isRecordingUITest {
      return UITestAuthoritativeDirectoryUseCase()
    }
    return AuthoritativeDirectoryWorkflow(access: fileStore)
  }

  nonisolated private static func buildMeetingLibrary(
    fileStore: MeetingFileStore
  )
    throws -> any MeetingLibraryUseCase
  {
    let applicationSupport = try applicationSupportDirectory()
    let databaseURL =
      applicationSupport
      .appending(path: "Quillvault", directoryHint: .isDirectory)
      .appending(path: "meeting-catalog.sqlite")
    let catalog = try GRDBMeetingCatalog.openRecovering(at: databaseURL)
    return MeetingLibraryWorkflow(
      directoryAccess: fileStore,
      catalog: catalog
    )
  }

  private static func makeModelProfiles(
    diagnostics: any DiagnosticRecorder
  ) -> any ModelProfileUseCase {
    RetryingModelProfileUseCase {
      let stateDirectory =
        try applicationSupportDirectory()
        .appending(path: "Quillvault", directoryHint: .isDirectory)
      let profileStore = try GRDBModelProfileStore.open(
        at: stateDirectory.appending(path: "model-profiles.sqlite")
      )
      return ModelProfileWorkflow(
        profiles: profileStore,
        credentials: KeychainModelCredentialStore(),
        provider: OpenAICompatibleProvider(diagnostics: diagnostics),
        usage: profileStore
      )
    }
  }

  private static func makeDefaultModelProfiles(
    diagnostics: any DiagnosticRecorder
  ) -> any ModelProfileUseCase {
    if isModelProfileUITest {
      return UITestModelProfileUseCase()
    }
    return makeModelProfiles(diagnostics: diagnostics)
  }

  private static func makeDefaultGeneration(
    fileStore: MeetingFileStore,
    modelProfiles: any ModelProfileUseCase,
    diagnostics: any DiagnosticRecorder,
    onJobRegistered: (@Sendable (GenerationJob) async -> Void)? = nil
  ) -> (any GenerationUseCase)? {
    guard
      !isMeetingDetailUITest,
      let executionAccess = modelProfiles as? any ModelProfileExecutionAccess
    else {
      return nil
    }
    return makeGeneration(
      fileStore: fileStore,
      profiles: executionAccess,
      diagnostics: diagnostics,
      onJobRegistered: onJobRegistered
    )
  }

  nonisolated private static func makeGeneration(
    fileStore: MeetingFileStore,
    profiles: any ModelProfileExecutionAccess,
    diagnostics: any DiagnosticRecorder,
    onJobRegistered: (@Sendable (GenerationJob) async -> Void)? = nil
  ) -> (any GenerationUseCase)? {
    do {
      let stateDirectory =
        try applicationSupportDirectory()
        .appending(path: "Quillvault", directoryHint: .isDirectory)
      let jobs = try GRDBGenerationJobStore.open(
        at: stateDirectory.appending(path: "generation-state.sqlite")
      )
      return GenerationWorkflow(
        jobs: jobs,
        assets: fileStore,
        profiles: profiles,
        provider: OpenAICompatibleProvider(diagnostics: diagnostics),
        diagnostics: diagnostics,
        onJobRegistered: onJobRegistered
      )
    } catch {
      return nil
    }
  }

  private static func makeRecording(
    fileStore: MeetingFileStore,
    diagnostics: any DiagnosticRecorder
  ) -> any RecordingUseCase {
    RetryingRecordingUseCase {
      try buildRecording(fileStore: fileStore, diagnostics: diagnostics)
    }
  }

  private static func makeDefaultRecording(
    fileStore: MeetingFileStore,
    diagnostics: any DiagnosticRecorder
  ) -> any RecordingUseCase {
    if isRecordingUITest {
      return UITestRecordingUseCase()
    }
    return makeRecording(fileStore: fileStore, diagnostics: diagnostics)
  }

  private static var isRecordingUITest: Bool {
    ProcessInfo.processInfo.arguments.contains("-ui-test-recording")
      && ProcessInfo.processInfo.environment[
        "QUILLVAULT_RECORDING_UI_TEST"
      ] == "1"
  }

  private static var isMeetingDetailUITest: Bool {
    ProcessInfo.processInfo.arguments.contains("-ui-test-meeting-detail")
      && ProcessInfo.processInfo.environment[
        "QUILLVAULT_MEETING_DETAIL_UI_TEST"
      ] == "1"
  }

  private static var isModelProfileUITest: Bool {
    ProcessInfo.processInfo.arguments.contains("-ui-test-model-profiles")
      && ProcessInfo.processInfo.environment[
        "QUILLVAULT_MODEL_PROFILE_UI_TEST"
      ] == "1"
  }

  nonisolated private static func buildRecording(
    fileStore: MeetingFileStore,
    diagnostics: any DiagnosticRecorder
  ) throws -> any RecordingUseCase {
    let stateDirectory =
      try applicationSupportDirectory()
      .appending(path: "Quillvault", directoryHint: .isDirectory)
    let stateURL = stateDirectory.appending(path: "recording-state.sqlite")
    let capture = AudioCaptureEngine(fileStore: fileStore)
    let recording = RecordingWorkflow(
      capture: capture,
      store: try GRDBRecordingSessionStore.open(at: stateURL),
      consentStore: UserDefaultsRecordingConsentStore(),
      makeMeetingID: {
        MeetingID(rawValue: UUID())
      },
      now: {
        Date()
      },
      diagnostics: diagnostics
    )
    let primaryTranscriptionJobs = try GRDBTranscriptionJobStore.open(
      at: stateDirectory.appending(path: "transcription-state.sqlite")
    )
    let transcription = TranscriptionWorkflow(
      engine: SpeechAnalyzerTranscriptionEngine(),
      publisher: FileTranscriptPublisher(),
      jobs: ResilientTranscriptionJobStore(
        primary: primaryTranscriptionJobs,
        fallbackURL: stateDirectory.appending(
          path: "pending-transcriptions.json"
        )
      ),
      assetAccess: fileStore,
      recoverySource: fileStore,
      diagnostics: diagnostics
    )
    return TranscribingRecordingUseCase(
      recording: recording,
      capture: capture,
      speech: SpeechAnalyzerTranscriptionEngine(),
      transcription: transcription,
      localeIdentifier: Locale.current.identifier
    )
  }

  nonisolated private static func applicationSupportDirectory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
  }

  private static func makeDiagnostics() -> (
    recorder: any DiagnosticRecorder,
    useCase: any DiagnosticsUseCase
  ) {
    let store: any DiagnosticStore
    if let applicationSupport = try? applicationSupportDirectory(),
      let storeValue = try? GRDBDiagnosticStore.open(
        at:
          applicationSupport
          .appending(path: "Quillvault", directoryHint: .isDirectory)
          .appending(path: "diagnostics.sqlite")
      )
    {
      store = storeValue
    } else {
      store = NoopDiagnosticStore()
    }
    return (store, DiagnosticsWorkflow(store: store))
  }
}

private struct MeetingAudioFileAccessAdapter: MeetingAudioFileAccess {
  let store: MeetingFileStore

  func beginAudioPlayback(
    sourceID: MeetingAudioSourceID
  ) async throws -> URL {
    try await store.beginAudioPlayback(sourceID: sourceID)
  }

  func endAudioPlayback(sourceID: MeetingAudioSourceID) async {
    await store.endAudioPlayback(sourceID: sourceID)
  }
}

private struct UITestAuthoritativeDirectoryUseCase:
  AuthoritativeDirectoryUseCase
{
  private let directory = AuthoritativeDirectory(
    id: AuthoritativeDirectoryID(rawValue: "ui-test-directory"),
    displayName: "UI Test Vault",
    kind: .userSelected
  )

  func restore() async throws -> AuthoritativeDirectory? {
    directory
  }

  func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    directory
  }
}

private struct UITestMeetingLibraryUseCase: MeetingLibraryUseCase {
  private let snapshot: MeetingLibrarySnapshot

  init(
    snapshot: MeetingLibrarySnapshot = MeetingLibrarySnapshot(
      directory: AuthoritativeDirectory(
        id: AuthoritativeDirectoryID(rawValue: "ui-test-directory"),
        displayName: "UI Test Vault",
        kind: .userSelected
      ),
      meetings: [],
      diagnosticCount: 0
    )
  ) {
    self.snapshot = snapshot
  }

  func restore() async throws -> MeetingLibrarySnapshot {
    snapshot
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    snapshot
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    snapshot
  }

  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry] {
    snapshot.meetings.filter { meeting in
      let matchesText =
        query.text.isEmpty
        || meeting.title?.localizedCaseInsensitiveContains(query.text) == true
      let matchesStart =
        query.createdFrom.map { meeting.createdAt >= $0 } ?? true
      let matchesEnd =
        query.createdThrough.map { meeting.createdAt <= $0 } ?? true
      let matchesStatus =
        query.statuses.isEmpty || query.statuses.contains(meeting.status)
      let matchesModel =
        query.modelName.map {
          meeting.modelName?.caseInsensitiveCompare($0) == .orderedSame
        } ?? true
      return matchesText && matchesStart && matchesEnd && matchesStatus && matchesModel
    }
  }
}

private actor UITestRecordingUseCase: RecordingUseCase {
  private var hasAcknowledgedNotice = false
  private var activeSession: RecordingSession?

  func restore() async throws -> RecordingSnapshot? {
    activeSession.map {
      RecordingSnapshot(session: $0, activity: .recording)
    }
  }

  func acknowledgeRecordingNotice() async throws {
    hasAcknowledgedNotice = true
  }

  func start() async throws -> RecordingSnapshot {
    guard hasAcknowledgedNotice else {
      throw RecordingError.recordingConsentRequired
    }
    guard activeSession == nil else {
      throw RecordingError.alreadyRecording
    }
    let session = RecordingSession(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "A8480D38-FBA5-49F4-B396-ED63BB96FA7C")!
      ),
      startedAt: Date()
    )
    activeSession = session
    return RecordingSnapshot(session: session, activity: .recording)
  }

  func stop() async throws -> RecordingCompletion {
    guard let session = activeSession else {
      throw RecordingError.noActiveRecording
    }
    activeSession = nil
    return RecordingCompletion(
      session: session,
      audio: RecordedAudio(
        durationSeconds: 1,
        packetCount: 1,
        byteCount: 1
      )
    )
  }

  func captureEvents(
    meetingID: MeetingID
  ) -> AsyncStream<RecordingCaptureEvent> {
    let interruptedAt = Date(timeIntervalSince1970: 1_722_470_420)
    return AsyncStream { continuation in
      continuation.yield(
        .interruptionBegan(
          at: interruptedAt,
          reason: .routeChange
        )
      )
      continuation.yield(
        .interruptionEnded(
          at: interruptedAt.addingTimeInterval(5),
          didResume: true
        )
      )
      continuation.finish()
    }
  }

  func catchUpLiveTranscript() async {}

  func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    []
  }
}
