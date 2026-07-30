import Application
import AudioCapture
import Domain
import Foundation
import HomeFeature
import MeetingFileStore
import MeetingsFeature
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

  init(
    router: AppRouter = AppRouter(),
    meetingLibrary: (any MeetingLibraryUseCase)? = nil,
    recording: (any RecordingUseCase)? = nil
  ) {
    self.router = router
    let fileStore = MeetingFileStore()
    let resolvedMeetingLibrary =
      meetingLibrary ?? Self.makeDefaultMeetingLibrary(fileStore: fileStore)
    let directoryAuthorization = Self.makeDefaultDirectoryAuthorization(
      fileStore: fileStore
    )
    let resolvedRecording =
      recording ?? Self.makeDefaultRecording(fileStore: fileStore)
    recordingModel = HomeRecordingModel(
      recording: resolvedRecording,
      directory: directoryAuthorization
    )
    meetingsModel = MeetingsModel(
      library: resolvedMeetingLibrary,
      transcriptionRecovery: resolvedRecording
    )
    settingsModel = SettingsModel(
      directory: directoryAuthorization,
      library: resolvedMeetingLibrary
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
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-test-recording") {
        return UITestMeetingLibraryUseCase()
      }
    #endif
    return makeMeetingLibrary(fileStore: fileStore)
  }

  private static func makeDefaultDirectoryAuthorization(
    fileStore: MeetingFileStore
  ) -> any AuthoritativeDirectoryUseCase {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-test-recording") {
        return UITestAuthoritativeDirectoryUseCase()
      }
    #endif
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

  private static func makeRecording(
    fileStore: MeetingFileStore
  ) -> any RecordingUseCase {
    RetryingRecordingUseCase {
      try buildRecording(fileStore: fileStore)
    }
  }

  private static func makeDefaultRecording(
    fileStore: MeetingFileStore
  ) -> any RecordingUseCase {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-ui-test-recording") {
        return UITestRecordingUseCase()
      }
    #endif
    return makeRecording(fileStore: fileStore)
  }

  nonisolated private static func buildRecording(
    fileStore: MeetingFileStore
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
      }
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
      recoverySource: fileStore
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
}

#if DEBUG
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
    private let snapshot = MeetingLibrarySnapshot(
      directory: AuthoritativeDirectory(
        id: AuthoritativeDirectoryID(rawValue: "ui-test-directory"),
        displayName: "UI Test Vault",
        kind: .userSelected
      ),
      meetings: [],
      diagnosticCount: 0
    )

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

    func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
      []
    }
  }
#endif
