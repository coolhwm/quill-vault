import Application
import Domain
import Foundation
import Testing

@testable import HomeFeature

@MainActor
@Suite("Home recording model")
struct HomeRecordingModelTests {
  @Test("Successful start presents the recording session")
  func startPresentsSession() async {
    let useCase = RecordingUseCaseStub()
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()

    #expect(model.state == .recording(.fixture()))
    #expect(model.isSessionPresented)
  }

  @Test("A shortcut start immediately projects the shared recording state")
  func shortcutStartProjectsRecordingState() {
    let snapshot = RecordingSnapshot(
      session: .fixture(),
      activity: .recording
    )
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(),
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    model.presentQuickStartOutcome(.started(snapshot))

    #expect(model.state == .recording(.fixture()))
    #expect(model.isSessionPresented)
  }

  @Test("A shortcut authorization failure opens the matching app recovery")
  func shortcutFailureProjectsAuthorizationRecovery() {
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(),
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    model.presentQuickStartOutcome(
      .requiresAppAttention(.authoritativeDirectory(.renewAccess))
    )

    #expect(model.directoryState == .recoveryRequired(.renewAccess))
    #expect(
      model.state == .startFailed(.authoritativeDirectoryUnavailable)
    )
  }

  @Test("First recording presents notice before retrying start")
  func noticeIsAcknowledged() async {
    let useCase = RecordingUseCaseStub(startErrors: [.recordingConsentRequired])
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    #expect(model.isRecordingNoticePresented)

    await model.acknowledgeNoticeAndStart()
    #expect(await useCase.acknowledgementCount == 1)
    #expect(model.state == .recording(.fixture()))
  }

  @Test("Stop failure keeps the focused screen available for retry")
  func stopFailureCanRetry() async {
    let useCase = RecordingUseCaseStub(stopError: .recordingWriteFailed)
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    await model.stop()

    #expect(
      model.state == .finishFailed(.fixture(), .recordingWriteFailed)
    )
    #expect(model.isSessionPresented)
  }

  @Test("Saved audio automatically finalizes the transcript without a retry tap")
  func pendingTranscriptAutoFinalizes() async {
    let revision = TranscriptRevision(
      meetingID: RecordingSession.fixture().meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(audioDurationSeconds: 60, segments: [])
    )
    let useCase = RecordingUseCaseStub(
      recoveryResults: [
        TranscriptionRecoveryResult(
          meetingID: revision.meetingID,
          result: .success(revision)
        )
      ]
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.selectDirectory(opaqueReference: "file:///vault")
    await model.start()

    await model.stop()

    #expect(!model.isSessionPresented)
    for _ in 0..<200 {
      if case .completed(let completion) = model.state,
        completion.transcriptRevision != nil
      {
        break
      }
      await Task.yield()
    }

    guard case .completed(let recovered) = model.state else {
      Issue.record("Expected recovered recording completion")
      return
    }
    #expect(recovered.transcriptRevision == revision)
    #expect(model.processingPhase == .awaitingMinutes)
    #expect(model.transcriptRecoveryState == .idle)
    #expect(await useCase.recoveryCount >= 1)
  }

  @Test("Transcript failure shows retry and recovers after a manual retry")
  func transcriptFailureCanRetry() async {
    let revision = TranscriptRevision(
      meetingID: RecordingSession.fixture().meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(audioDurationSeconds: 60, segments: [])
    )
    let useCase = RecordingUseCaseStub(
      recoveryResults: [
        TranscriptionRecoveryResult(
          meetingID: revision.meetingID,
          result: .failure(.recognitionFailed)
        ),
        TranscriptionRecoveryResult(
          meetingID: revision.meetingID,
          result: .success(revision)
        ),
      ]
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.selectDirectory(opaqueReference: "file:///vault")
    await model.start()
    await model.stop()

    for _ in 0..<200 {
      if case .transcriptFailed = model.processingPhase {
        break
      }
      await Task.yield()
    }
    #expect(model.processingPhase == .transcriptFailed(.recognitionFailed))

    await model.retryTranscript()

    for _ in 0..<200 {
      if case .completed(let completion) = model.state,
        completion.transcriptRevision != nil
      {
        break
      }
      await Task.yield()
    }
    guard case .completed(let recovered) = model.state else {
      Issue.record("Expected recovered recording completion")
      return
    }
    #expect(recovered.transcriptRevision == revision)
    #expect(model.processingPhase == .awaitingMinutes)
    #expect(await useCase.recoveryCount >= 2)
  }

  @Test("Automatic generation starts minutes after transcript is ready")
  func automaticGenerationStartsMinutes() async {
    let revision = TranscriptRevision(
      meetingID: RecordingSession.fixture().meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(audioDurationSeconds: 60, segments: [])
    )
    let meeting = MeetingIndexEntry(
      id: revision.meetingID,
      createdAt: Date(timeIntervalSince1970: 1_722_470_400),
      relativeDirectory: "meeting-test",
      assets: [.recording, .transcript],
      durationSeconds: 60,
      transcriptRevisionID: revision.id,
      transcriptFingerprint: revision.contentFingerprint
    )
    let job = GenerationJob(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      meetingID: revision.meetingID,
      transcriptRevisionID: revision.id,
      transcriptFingerprint: revision.contentFingerprint,
      modelProfile: ModelProfileSnapshot(
        profileID: ModelProfileID(
          rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        ),
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "gpt-test",
        parameters: ModelGenerationParameters(),
        credentialReference: ModelCredentialReference(
          rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
      ),
      createdAt: Date(timeIntervalSince1970: 1_722_470_500),
      updatedAt: Date(timeIntervalSince1970: 1_722_470_500),
      state: .running,
      stage: .summarizing,
      progress: 20
    )
    let generation = GenerationUseCaseStub(
      startSnapshot: GenerationSnapshot(job: job)
    )
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(
        recoveryResults: [
          TranscriptionRecoveryResult(
            meetingID: revision.meetingID,
            result: .success(revision)
          )
        ]
      ),
      directory: AuthoritativeDirectoryUseCaseStub(),
      library: MeetingLibraryUseCaseStub(meetings: [meeting]),
      generation: generation,
      modelProfiles: ModelProfileUseCaseStub(
        collection: ModelProfileCollection(
          profiles: [
            ModelProfile(
              id: job.modelProfile.profileID,
              name: "Test",
              baseURL: job.modelProfile.baseURL,
              model: job.modelProfile.model,
              credentialReference: job.modelProfile.credentialReference,
              isUsable: true
            )
          ],
          currentProfileID: job.modelProfile.profileID,
          automaticGeneration: AutomaticGenerationPreferences(
            isEnabled: true,
            disclosureAcknowledged: true
          )
        )
      )
    )
    await model.selectDirectory(opaqueReference: "file:///vault")
    await model.start()
    await model.stop()

    for _ in 0..<300 {
      if case .generatingMinutes = model.processingPhase {
        break
      }
      await Task.yield()
    }
    guard case .generatingMinutes(let snapshot) = model.processingPhase else {
      Issue.record("Expected generating minutes phase, got \(model.processingPhase)")
      return
    }
    #expect(snapshot.job.progress == 20)
    #expect(await generation.startCount == 1)
  }

  @Test("Optimize failure stops auto generation until user skips or retries")
  func optimizeFailureBlocksAutoGeneration() async {
    let revision = TranscriptRevision(
      meetingID: RecordingSession.fixture().meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(audioDurationSeconds: 60, segments: [])
    )
    let meeting = MeetingIndexEntry(
      id: revision.meetingID,
      createdAt: Date(timeIntervalSince1970: 1_722_470_400),
      relativeDirectory: "meeting-test",
      assets: [.recording, .transcript],
      durationSeconds: 60,
      transcriptRevisionID: revision.id,
      transcriptFingerprint: revision.contentFingerprint
    )
    let completedJob = GenerationJob(
      id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
      meetingID: revision.meetingID,
      transcriptRevisionID: revision.id,
      transcriptFingerprint: revision.contentFingerprint,
      modelProfile: ModelProfileSnapshot(
        profileID: ModelProfileID(
          rawValue: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        ),
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "gpt-test",
        parameters: ModelGenerationParameters(),
        credentialReference: ModelCredentialReference(
          rawValue: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
      ),
      createdAt: Date(timeIntervalSince1970: 1_722_470_500),
      updatedAt: Date(timeIntervalSince1970: 1_722_470_600),
      completedAt: Date(timeIntervalSince1970: 1_722_470_600),
      state: .completed,
      stage: .completed,
      progress: 100
    )
    let generation = GenerationUseCaseStub(
      startSnapshot: GenerationSnapshot(job: completedJob)
    )
    let quality = TranscriptQualityUseCaseStub(shouldFail: true)
    let profileID = completedJob.modelProfile.profileID
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(
        recoveryResults: [
          TranscriptionRecoveryResult(
            meetingID: revision.meetingID,
            result: .success(revision)
          )
        ]
      ),
      directory: AuthoritativeDirectoryUseCaseStub(),
      library: MeetingLibraryUseCaseStub(meetings: [meeting]),
      generation: generation,
      modelProfiles: ModelProfileUseCaseStub(
        collection: ModelProfileCollection(
          profiles: [
            ModelProfile(
              id: profileID,
              name: "Test",
              baseURL: completedJob.modelProfile.baseURL,
              model: completedJob.modelProfile.model,
              credentialReference: completedJob.modelProfile.credentialReference,
              isUsable: true
            )
          ],
          currentProfileID: profileID,
          automaticGeneration: AutomaticGenerationPreferences(
            isEnabled: true,
            disclosureAcknowledged: true
          ),
          transcriptQuality: TranscriptQualityPreferences(isEnabled: true)
        )
      ),
      transcriptQuality: quality
    )
    await model.selectDirectory(opaqueReference: "file:///vault")
    await model.start()
    await model.stop()

    for _ in 0..<200 {
      if model.processingPhase == .optimizeFailed {
        break
      }
      await Task.yield()
    }
    #expect(model.processingPhase == .optimizeFailed)
    #expect(await generation.startCount == 0)
    #expect(await quality.publishCount == 1)

    await model.skipOptimizeAndStartMinutes()
    for _ in 0..<200 {
      if model.processingPhase == .minutesCompleted {
        break
      }
      await Task.yield()
    }
    #expect(model.processingPhase == .minutesCompleted)
    #expect(await generation.startCount == 1)
  }

  @Test("Manual minutes generation is available when automatic generation is off")
  func manualMinutesGenerationWhenAutoOff() async {
    let revision = TranscriptRevision(
      meetingID: RecordingSession.fixture().meetingID,
      localeIdentifier: "zh-CN",
      timeline: TranscriptTimeline(audioDurationSeconds: 60, segments: [])
    )
    let meeting = MeetingIndexEntry(
      id: revision.meetingID,
      createdAt: Date(timeIntervalSince1970: 1_722_470_400),
      relativeDirectory: "meeting-test",
      assets: [.recording, .transcript],
      durationSeconds: 60,
      transcriptRevisionID: revision.id,
      transcriptFingerprint: revision.contentFingerprint
    )
    let completedJob = GenerationJob(
      id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
      meetingID: revision.meetingID,
      transcriptRevisionID: revision.id,
      transcriptFingerprint: revision.contentFingerprint,
      modelProfile: ModelProfileSnapshot(
        profileID: ModelProfileID(
          rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        ),
        baseURL: URL(string: "https://api.example.com/v1")!,
        model: "gpt-test",
        parameters: ModelGenerationParameters(),
        credentialReference: ModelCredentialReference(
          rawValue: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
      ),
      createdAt: Date(timeIntervalSince1970: 1_722_470_500),
      updatedAt: Date(timeIntervalSince1970: 1_722_470_600),
      completedAt: Date(timeIntervalSince1970: 1_722_470_600),
      state: .completed,
      stage: .completed,
      progress: 100
    )
    let generation = GenerationUseCaseStub(
      startSnapshot: GenerationSnapshot(job: completedJob)
    )
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(
        recoveryResults: [
          TranscriptionRecoveryResult(
            meetingID: revision.meetingID,
            result: .success(revision)
          )
        ]
      ),
      directory: AuthoritativeDirectoryUseCaseStub(),
      library: MeetingLibraryUseCaseStub(meetings: [meeting]),
      generation: generation,
      modelProfiles: ModelProfileUseCaseStub(
        collection: ModelProfileCollection(
          profiles: [
            ModelProfile(
              id: completedJob.modelProfile.profileID,
              name: "Test",
              baseURL: completedJob.modelProfile.baseURL,
              model: completedJob.modelProfile.model,
              credentialReference: completedJob.modelProfile.credentialReference,
              isUsable: true
            )
          ],
          currentProfileID: completedJob.modelProfile.profileID,
          automaticGeneration: AutomaticGenerationPreferences(
            isEnabled: false,
            disclosureAcknowledged: true
          )
        )
      )
    )
    await model.selectDirectory(opaqueReference: "file:///vault")
    await model.start()
    await model.stop()

    for _ in 0..<200 {
      if model.processingPhase == .awaitingMinutes {
        break
      }
      await Task.yield()
    }
    #expect(model.processingPhase == .awaitingMinutes)
    #expect(await generation.startCount == 0)

    await model.startMinutesGeneration()

    for _ in 0..<200 {
      if model.processingPhase == .minutesCompleted {
        break
      }
      await Task.yield()
    }
    #expect(model.processingPhase == .minutesCompleted)
    #expect(await generation.startCount == 1)
  }

  @Test("Repeated stop taps stop the audio only once")
  func repeatedStopIsIdempotent() async {
    let useCase = RecordingUseCaseStub(stopDelay: .milliseconds(100))
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    let firstStop = Task {
      await model.stop()
    }
    while model.state != .finishing(.fixture()) {
      await Task.yield()
    }
    await model.stop()
    await firstStop.value

    #expect(await useCase.stopCount == 1)
    #expect(!model.isSessionPresented)
  }

  @Test("Invalid audio exits the recording screen without claiming success")
  func invalidAudioExitsFocusedScreen() async {
    let useCase = RecordingUseCaseStub(stopError: .invalidRecordedAudio)
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()

    await model.stop()

    #expect(model.state == .startFailed(.invalidRecordedAudio))
    #expect(!model.isSessionPresented)
  }

  @Test("An interrupted meeting offers ending and transcript recovery")
  func interruptedMeetingCanEnd() async {
    let audio = RecordedAudio(
      durationSeconds: 45,
      packetCount: 2_000,
      byteCount: 256_000
    )
    let interruptedAt = RecordingSession.fixture().startedAt
      .addingTimeInterval(40)
    let useCase = RecordingUseCaseStub(
      restoredSnapshot: RecordingSnapshot(
        session: .fixture(),
        activity: .interrupted(audio),
        captureEvents: [
          .interruptionBegan(
            at: interruptedAt,
            reason: .processTermination
          )
        ]
      )
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.restore()
    #expect(model.state == .interrupted(.fixture(), audio))
    #expect(
      model.interruptionGaps == [
        RecordingInterruptionGap(
          startedAt: interruptedAt,
          endedAt: nil,
          reason: .processTermination,
          didResume: false
        )
      ]
    )
    #expect(!model.isSessionPresented)

    await model.finishInterrupted()

    guard case .completed(let completion) = model.state else {
      Issue.record("Expected the interrupted recording to complete")
      return
    }
    #expect(completion.audio == audio)
    #expect(await useCase.finishInterruptedCount == 1)
  }

  @Test("An interrupted meeting can continue in the recording screen")
  func interruptedMeetingCanResume() async {
    let audio = RecordedAudio(
      durationSeconds: 45,
      packetCount: 2_000,
      byteCount: 256_000
    )
    let useCase = RecordingUseCaseStub(
      restoredSnapshot: RecordingSnapshot(
        session: .fixture(),
        activity: .interrupted(audio)
      )
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.restore()
    await model.resumeInterrupted()

    #expect(model.state == .recording(.fixture()))
    #expect(model.isSessionPresented)
    #expect(await useCase.resumeInterruptedCount == 1)
  }

  @Test("An interrupted meeting can be preserved before starting a new one")
  func interruptedMeetingCanStartNew() async {
    let audio = RecordedAudio(
      durationSeconds: 45,
      packetCount: 2_000,
      byteCount: 256_000
    )
    let useCase = RecordingUseCaseStub(
      restoredSnapshot: RecordingSnapshot(
        session: .fixture(),
        activity: .interrupted(audio)
      )
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.restore()
    await model.startNewAfterInterruption()

    #expect(model.state == .recording(.fixture()))
    #expect(await useCase.finishInterruptedCount == 1)
    #expect(await useCase.startCount == 1)
  }

  @Test("Live transcript projection follows the use-case stream")
  func liveTranscriptProjection() async {
    let useCase = RecordingUseCaseStub(
      liveSnapshots: [
        LiveTranscriptSnapshot(
          finalSegments: [
            TranscriptSegmentCandidate(
              startSeconds: 0,
              endSeconds: 1,
              text: "已确认"
            )
          ],
          volatileSegment: TranscriptSegmentCandidate(
            startSeconds: 1,
            endSeconds: 2,
            text: "临时"
          )
        )
      ]
    )
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    while model.liveTranscriptText.isEmpty {
      await Task.yield()
    }

    #expect(
      model.liveTranscriptText
        == "- [000.0–001.0] 已确认\n- [001.0–002.0] 临时"
    )
    #expect(model.isLiveTranscriptPinnedToBottom)
    #expect(model.liveTranscriptLatestLineID.hasPrefix("volatile:"))
  }

  @Test("Scrolling up unpins live transcript auto-follow until the user returns")
  func liveTranscriptPinFollowsScrollPosition() async {
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(),
      directory: AuthoritativeDirectoryUseCaseStub()
    )
    await model.start()
    #expect(model.isLiveTranscriptPinnedToBottom)

    model.updateLiveTranscriptPin(
      offsetY: 0,
      contentHeight: 400,
      visibleHeight: 200
    )
    #expect(!model.isLiveTranscriptPinnedToBottom)

    model.updateLiveTranscriptPin(
      offsetY: 160,
      contentHeight: 400,
      visibleHeight: 200
    )
    #expect(model.isLiveTranscriptPinnedToBottom)

    model.updateLiveTranscriptPin(
      offsetY: 0,
      contentHeight: 400,
      visibleHeight: 200
    )
    model.pinLiveTranscriptToBottom()
    #expect(model.isLiveTranscriptPinnedToBottom)
  }

  @Test("Audio interruption is retained as a visible gap after recovery")
  func captureInterruptionProjection() async {
    let interruptedAt = Date(timeIntervalSince1970: 1_722_470_420)
    let resumedAt = interruptedAt.addingTimeInterval(5)
    let began = RecordingCaptureEvent.interruptionBegan(
      at: interruptedAt,
      reason: .routeChange
    )
    let ended = RecordingCaptureEvent.interruptionEnded(
      at: resumedAt,
      didResume: true
    )
    let useCase = RecordingUseCaseStub(captureEvents: [began, ended])
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    for _ in 0..<100 {
      if model.interruptionGaps.first?.endedAt != nil {
        break
      }
      await Task.yield()
    }

    #expect(model.captureStatus == .active)
    #expect(
      model.interruptionGaps == [
        RecordingInterruptionGap(
          startedAt: interruptedAt,
          endedAt: resumedAt,
          reason: .routeChange,
          didResume: true
        )
      ]
    )
  }

  @Test("Failed automatic audio recovery is visible while recording")
  func captureResumeFailureProjection() async {
    let ended = RecordingCaptureEvent.interruptionEnded(
      at: Date(timeIntervalSince1970: 1_722_470_430),
      didResume: false
    )
    let useCase = RecordingUseCaseStub(captureEvents: [ended])
    let model = HomeRecordingModel(
      recording: useCase,
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()
    while model.captureStatus == .active {
      await Task.yield()
    }

    #expect(model.captureStatus == .resumeFailed)
  }

  @Test("Missing directory authorization prevents recording")
  func directoryAuthorizationPrecedesRecording() async {
    let recording = RecordingUseCaseStub()
    let model = HomeRecordingModel(
      recording: recording,
      directory: AuthoritativeDirectoryUseCaseStub(
        restoreError: .bookmarkMissing
      )
    )

    await model.restore()
    await model.start()

    #expect(model.directoryState == .recoveryRequired(.chooseDirectory))
    #expect(await recording.startCount == 0)
  }

  @Test("Lost directory access presents reauthorization after start fails")
  func lostDirectoryAccessRequiresReauthorization() async {
    let model = HomeRecordingModel(
      recording: RecordingUseCaseStub(
        startErrors: [.authoritativeDirectoryUnavailable]
      ),
      directory: AuthoritativeDirectoryUseCaseStub()
    )

    await model.start()

    #expect(model.directoryState == .recoveryRequired(.renewAccess))
    #expect(
      model.state == .startFailed(.authoritativeDirectoryUnavailable)
    )
  }
}

private actor RecordingUseCaseStub: RecordingUseCase {
  private var startErrors: [RecordingError]
  private let stopError: RecordingError?
  private let liveSnapshots: [LiveTranscriptSnapshot]
  private var recoveryResults: [TranscriptionRecoveryResult]
  private let stopDelay: Duration?
  private let restoredSnapshot: RecordingSnapshot?
  private let capturedCaptureEvents: [RecordingCaptureEvent]
  private(set) var acknowledgementCount = 0
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var resumeInterruptedCount = 0
  private(set) var finishInterruptedCount = 0
  private(set) var recoveryCount = 0
  private(set) var deliveredCaptureEventCount = 0

  init(
    startErrors: [RecordingError] = [],
    stopError: RecordingError? = nil,
    liveSnapshots: [LiveTranscriptSnapshot] = [],
    recoveryResults: [TranscriptionRecoveryResult] = [],
    stopDelay: Duration? = nil,
    restoredSnapshot: RecordingSnapshot? = nil,
    captureEvents: [RecordingCaptureEvent] = []
  ) {
    self.startErrors = startErrors
    self.stopError = stopError
    self.liveSnapshots = liveSnapshots
    self.recoveryResults = recoveryResults
    self.stopDelay = stopDelay
    self.restoredSnapshot = restoredSnapshot
    capturedCaptureEvents = captureEvents
  }

  func restore() async throws -> RecordingSnapshot? {
    restoredSnapshot
  }

  func acknowledgeRecordingNotice() async throws {
    acknowledgementCount += 1
  }

  func start() async throws -> RecordingSnapshot {
    startCount += 1
    if !startErrors.isEmpty {
      throw startErrors.removeFirst()
    }
    return RecordingSnapshot(
      session: .fixture(),
      activity: .recording
    )
  }

  func stop() async throws -> RecordingCompletion {
    stopCount += 1
    if let stopDelay {
      try await Task.sleep(for: stopDelay)
    }
    if let stopError {
      throw stopError
    }
    return RecordingCompletion(
      session: .fixture(),
      audio: RecordedAudio(
        durationSeconds: 60,
        packetCount: 2_000,
        byteCount: 512_000
      )
    )
  }

  func finishInterrupted() async throws -> RecordingCompletion {
    finishInterruptedCount += 1
    guard
      let restoredSnapshot,
      case .interrupted(let audio) = restoredSnapshot.activity
    else {
      throw RecordingError.noActiveRecording
    }
    return RecordingCompletion(
      session: restoredSnapshot.session,
      audio: audio
    )
  }

  func resumeInterrupted() async throws -> RecordingSnapshot {
    resumeInterruptedCount += 1
    guard let restoredSnapshot else {
      throw RecordingError.noActiveRecording
    }
    return RecordingSnapshot(
      session: restoredSnapshot.session,
      activity: .recording
    )
  }

  func liveTranscript(
    meetingID: MeetingID
  ) -> AsyncStream<LiveTranscriptSnapshot> {
    let snapshots = liveSnapshots
    return AsyncStream { continuation in
      for snapshot in snapshots {
        continuation.yield(snapshot)
      }
      continuation.finish()
    }
  }

  func captureEvents(
    meetingID: MeetingID
  ) -> AsyncStream<RecordingCaptureEvent> {
    let events = capturedCaptureEvents
    return AsyncStream { continuation in
      Task {
        for event in events {
          continuation.yield(event)
          deliveredCaptureEventCount += 1
        }
        continuation.finish()
      }
    }
  }

  func catchUpLiveTranscript() async {}

  func recoverPendingTranscriptions() -> [TranscriptionRecoveryResult] {
    recoveryCount += 1
    guard !recoveryResults.isEmpty else {
      return []
    }
    return [recoveryResults.removeFirst()]
  }
}

private actor GenerationUseCaseStub: GenerationUseCase {
  private let startSnapshot: GenerationSnapshot
  private(set) var startCount = 0
  private var latest: GenerationSnapshot?

  init(startSnapshot: GenerationSnapshot) {
    self.startSnapshot = startSnapshot
    latest = startSnapshot
  }

  func start(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    startCount += 1
    latest = startSnapshot
    return startSnapshot
  }

  func regenerate(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool
  ) async throws -> GenerationSnapshot {
    try await start(in: directory, meeting: meeting)
  }

  func resume(
    _ jobID: UUID,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool
  ) async throws -> GenerationSnapshot {
    startSnapshot
  }

  func load(meetingID: MeetingID) async throws -> GenerationSnapshot? {
    guard latest?.job.meetingID == meetingID else {
      return nil
    }
    return latest
  }

  func cancel(_ jobID: UUID) async {}
}

private actor TranscriptQualityUseCaseStub: TranscriptQualityUseCase {
  private let shouldFail: Bool
  private(set) var publishCount = 0

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func optimize(
    timeline: TranscriptTimeline,
    localeIdentifier: String
  ) async throws -> (timeline: TranscriptTimeline, metadata: TranscriptVersionMetadata) {
    (
      timeline,
      TranscriptVersionMetadata(
        strategyID: "offline-readability",
        strategyVersion: "v1",
        modelName: "test",
        createdAt: Date(timeIntervalSince1970: 1)
      )
    )
  }

  func optimizeAndPublish(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptVersionMetadata {
    publishCount += 1
    if shouldFail {
      throw TranscriptQualityAccessError.publicationFailed
    }
    return TranscriptVersionMetadata(
      strategyID: "offline-readability",
      strategyVersion: "v1",
      modelName: "test",
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}

private struct ModelProfileUseCaseStub: ModelProfileUseCase {
  let collection: ModelProfileCollection

  func load() async throws -> ModelProfileCollection {
    collection
  }

  func save(_ draft: ModelProfileDraft) async throws -> ModelProfile {
    collection.profiles[0]
  }

  func select(_ id: ModelProfileID) async throws {}

  func test(_ id: ModelProfileID) async throws -> ModelCapability {
    ModelCapability(providerDomain: "api.example.com", representativeContent: true)
  }

  func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async throws {}

  func deletionImpact(
    _ id: ModelProfileID
  ) async throws -> ModelProfileDeletionImpact {
    .safe
  }

  func delete(_ id: ModelProfileID, confirmed: Bool) async throws {}
}

private struct MeetingLibraryUseCaseStub: MeetingLibraryUseCase {
  let meetings: [MeetingIndexEntry]

  func restore() async throws -> MeetingLibrarySnapshot {
    MeetingLibrarySnapshot(
      directory: .fixture,
      meetings: meetings,
      diagnosticCount: 0
    )
  }

  func select(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  func rebuild() async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  func synchronize() async throws -> MeetingLibrarySnapshot {
    try await restore()
  }

  func search(_ query: MeetingSearchQuery) async throws -> [MeetingIndexEntry] {
    meetings
  }
}

private struct AuthoritativeDirectoryUseCaseStub: AuthoritativeDirectoryUseCase {
  let restoreError: DirectoryAccessError?

  init(restoreError: DirectoryAccessError? = nil) {
    self.restoreError = restoreError
  }

  func restore() async throws -> AuthoritativeDirectory? {
    if let restoreError {
      throw restoreError
    }
    return .fixture
  }

  func authorize(
    _ selection: AuthoritativeDirectorySelection
  ) async throws -> AuthoritativeDirectory {
    .fixture
  }
}

extension AuthoritativeDirectory {
  fileprivate static let fixture = Self(
    id: AuthoritativeDirectoryID(rawValue: "test-directory"),
    displayName: "Vault",
    kind: .userSelected
  )
}

extension RecordingSession {
  fileprivate static func fixture() -> Self {
    .init(
      meetingID: MeetingID(
        rawValue: UUID(uuidString: "C20549B1-AEE8-4F84-A250-CA3D761A84EA")!
      ),
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}
