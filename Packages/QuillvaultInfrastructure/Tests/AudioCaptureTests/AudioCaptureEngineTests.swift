import AVFAudio
import AudioToolbox
import Domain
import Foundation
import Testing

@testable import AudioCapture

@Suite("Audio capture engine")
struct AudioCaptureEngineTests {
  @Test("One engine owns at most one recorder")
  func singleCaptureOwner() async throws {
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy()
    let engine = makeEngine(files: files, drivers: drivers)
    let first = RecordingSession.fixture()

    _ = try await engine.start(first)

    await #expect(throws: RecordingError.alreadyRecording) {
      try await engine.start(.fixture(id: UUID()))
    }
    #expect(drivers.count == 1)
  }

  @Test("Concurrent starts cannot pass the permission suspension together")
  func concurrentStartsAreSerialized() async throws {
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy()
    let permission = SuspendingPermission()
    let engine = makeEngine(
      files: files,
      drivers: drivers,
      permission: permission
    )
    let first = RecordingSession.fixture()
    let firstTask = Task {
      try await engine.start(first)
    }
    await permission.waitUntilRequested()

    await #expect(throws: RecordingError.alreadyRecording) {
      _ = try await engine.start(.fixture(id: UUID()))
    }
    await permission.resolve(true)
    _ = try await firstTask.value

    #expect(drivers.count == 1)
    #expect(await files.publishedIDs == [first.meetingID])
  }

  @Test("A recorder start failure cleans up only its reservation")
  func startFailureCleansReservation() async {
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy(startError: DriverFailure())
    let engine = makeEngine(files: files, drivers: drivers)
    let session = RecordingSession.fixture()

    await #expect(throws: RecordingError.captureCouldNotStart) {
      try await engine.start(session)
    }
    #expect(await files.cancelledIDs == [session.meetingID])
    #expect(await files.publishedIDs.isEmpty)
  }

  @Test("Cancellation stops the driver and removes its reservation")
  func cancellationCleansReservation() async throws {
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy()
    let engine = makeEngine(files: files, drivers: drivers)
    let session = RecordingSession.fixture()
    _ = try await engine.start(session)

    await engine.cancel(meetingID: session.meetingID)

    #expect(drivers.stopCount == 1)
    #expect(await files.cancelledIDs == [session.meetingID])
  }

  @Test("Best-effort frames are exposed only for the active recording")
  func exposesLiveFramesForActiveMeeting() async throws {
    let expected = AudioFrame(
      samples: Data([0, 0, 0, 0]),
      sampleRate: 44_100,
      channelCount: 1,
      frameCount: 1,
      startSeconds: 0
    )
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy(frames: [expected])
    let engine = makeEngine(files: files, drivers: drivers)
    let session = RecordingSession.fixture()
    _ = try await engine.start(session)

    var received: [AudioFrame] = []
    for await frame in await engine.liveFrames(meetingID: session.meetingID) {
      received.append(frame)
    }
    var wrongMeetingFrames = 0
    for await _ in await engine.liveFrames(meetingID: MeetingID(rawValue: UUID())) {
      wrongMeetingFrames += 1
    }

    #expect(received == [expected])
    #expect(wrongMeetingFrames == 0)
  }

  @Test("Audio-session interruption boundaries are persisted")
  func persistsInterruptionBoundaries() async throws {
    let beganAt = Date(timeIntervalSince1970: 1_722_470_430)
    let endedAt = Date(timeIntervalSince1970: 1_722_470_442)
    let expected: [RecordingCaptureEvent] = [
      .interruptionBegan(at: beganAt, reason: .mediaServicesReset),
      .interruptionEnded(at: endedAt, didResume: false),
    ]
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy(events: expected)
    let engine = makeEngine(files: files, drivers: drivers)
    let session = RecordingSession.fixture()

    _ = try await engine.start(session)
    while await files.captureEvents.count < expected.count {
      await Task.yield()
    }

    #expect(await files.captureEvents == expected)
  }

  @Test("Stopping retries an interruption boundary that was not persisted")
  func retriesInterruptionBoundaryBeforePublication() async throws {
    let event = RecordingCaptureEvent.interruptionBegan(
      at: Date(timeIntervalSince1970: 1_722_470_430),
      reason: .routeChange
    )
    let files = RecordingFilesStub(captureEventFailures: 1)
    let drivers = DriverFactorySpy(events: [event])
    let engine = makeEngine(files: files, drivers: drivers)
    let session = RecordingSession.fixture()

    _ = try await engine.start(session)
    while await files.captureEventAttempts == 0 {
      await Task.yield()
    }
    _ = try await engine.stop(meetingID: session.meetingID)

    #expect(await files.captureEventAttempts == 2)
    #expect(await files.captureEvents == [event])
    #expect(await files.finishedIDs == [session.meetingID])
  }

  @Test("Stopping finishes interruption observers")
  func stopFinishesCaptureEventObservers() async throws {
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy()
    let engine = makeEngine(files: files, drivers: drivers)
    let session = RecordingSession.fixture()
    _ = try await engine.start(session)
    let events = await engine.captureEvents(meetingID: session.meetingID)
    let observer = Task {
      for await _ in events {}
      return true
    }

    _ = try await engine.stop(meetingID: session.meetingID)
    let observerFinished = await withTaskGroup(of: Bool.self) { group in
      group.addTask { await observer.value }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(100))
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
    observer.cancel()

    #expect(observerFinished)
  }

  @Test("Stopping validates audio and releases directory access")
  func stopValidatesAndFinishes() async throws {
    let audio = RecordedAudio(
      durationSeconds: 60,
      packetCount: 2_000,
      byteCount: 256_000
    )
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy()
    let engine = makeEngine(
      files: files,
      drivers: drivers,
      validator: ValidatorStub(audio: audio)
    )
    let session = RecordingSession.fixture()
    _ = try await engine.start(session)

    let result = try await engine.stop(meetingID: session.meetingID)

    #expect(result == audio)
    #expect(await files.finishedIDs == [session.meetingID])
    #expect(drivers.stopCount == 1)
  }

  @Test("Cold start inspects before publishing a valid interrupted recording")
  func recoversInterruptedRecording() async throws {
    let session = RecordingSession.fixture()
    let reservation = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: URL(fileURLWithPath: "/authorized/meeting"),
      recordingURL: URL(fileURLWithPath: "/authorized/meeting/recording.m4a")
    )
    let audio = RecordedAudio(
      durationSeconds: 4,
      packetCount: 128,
      byteCount: 4_096
    )
    let files = RecordingFilesStub(recoveredReservation: reservation)
    let engine = makeEngine(
      files: files,
      drivers: DriverFactorySpy(),
      validator: ValidatorStub(audio: audio)
    )

    let result = try await engine.recoverInterrupted(session)

    #expect(result == audio)
    #expect(await files.finishedIDs.isEmpty)

    let finished = try await engine.finishInterrupted(session)

    #expect(finished == audio)
    #expect(await files.finishedIDs == [session.meetingID])
  }

  @Test("Cancellation while publishing an interrupted recording remains cancellation")
  func interruptedRecoveryPropagatesCancellation() async {
    let session = RecordingSession.fixture()
    let reservation = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: URL(fileURLWithPath: "/authorized/meeting"),
      recordingURL: URL(fileURLWithPath: "/authorized/meeting/recording.m4a")
    )
    let files = RecordingFilesStub(
      recoveredReservation: reservation,
      finishError: CancellationError()
    )
    let engine = makeEngine(
      files: files,
      drivers: DriverFactorySpy(),
      validator: ValidatorStub(
        audio: RecordedAudio(durationSeconds: 4, packetCount: 128, byteCount: 4_096)
      )
    )

    _ = try? await engine.recoverInterrupted(session)
    await #expect(throws: CancellationError.self) {
      _ = try await engine.finishInterrupted(session)
    }
    #expect(await files.finishedIDs.isEmpty)
    #expect(await files.abandonedIDs.isEmpty)
  }

  @Test("Continuing an interrupted meeting merges through a validated candidate")
  func resumesInterruptedRecordingWithoutReplacingOriginalEarly() async throws {
    let session = RecordingSession.fixture()
    let original = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: URL(fileURLWithPath: "/authorized/meeting"),
      recordingURL: URL(fileURLWithPath: "/authorized/meeting/recording.m4a")
    )
    let continuation = RecordingContinuationReservation(
      meetingID: session.meetingID,
      originalRecordingURL: original.recordingURL,
      continuationURL: original.directoryURL.appending(
        path: "recording-continuation.m4a"
      ),
      candidateURL: original.directoryURL.appending(
        path: ".recording-merged.m4a"
      )
    )
    let files = RecordingFilesStub(
      recoveredReservation: original,
      continuationReservation: continuation
    )
    let drivers = DriverFactorySpy()
    let merger = AudioMergerSpy()
    let expected = RecordedAudio(
      durationSeconds: 35,
      packetCount: 1_600,
      byteCount: 120_000
    )
    let engine = makeEngine(
      files: files,
      drivers: drivers,
      validator: ValidatorStub(audio: expected),
      merger: merger
    )

    _ = try await engine.recoverInterrupted(session)
    _ = try await engine.resumeInterrupted(session)
    let result = try await engine.stop(meetingID: session.meetingID)

    #expect(result == expected)
    #expect(drivers.startedURLs == [continuation.continuationURL])
    #expect(
      merger.requests == [
        .init(
          originalURL: continuation.originalRecordingURL,
          continuationURL: continuation.continuationURL,
          candidateURL: continuation.candidateURL
        )
      ]
    )
    #expect(await files.committedContinuationIDs == [session.meetingID])
    #expect(await files.finishedIDs == [session.meetingID])
  }

  @Test("Cold start incorporates a valid continuation left by termination")
  func coldStartRecoversValidContinuation() async throws {
    let session = RecordingSession.fixture()
    let original = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: URL(fileURLWithPath: "/authorized/meeting"),
      recordingURL: URL(fileURLWithPath: "/authorized/meeting/recording.m4a")
    )
    let continuation = RecordingContinuationReservation(
      meetingID: session.meetingID,
      originalRecordingURL: original.recordingURL,
      continuationURL: original.directoryURL.appending(path: ".continuation.m4a"),
      candidateURL: original.directoryURL.appending(path: ".candidate.m4a")
    )
    let files = RecordingFilesStub(
      recoveredReservation: original,
      continuationReservation: continuation,
      recoverContinuation: true
    )
    let merger = AudioMergerSpy()
    let expected = RecordedAudio(
      durationSeconds: 35,
      packetCount: 1_600,
      byteCount: 120_000
    )
    let engine = makeEngine(
      files: files,
      drivers: DriverFactorySpy(),
      validator: ValidatorStub(audio: expected),
      merger: merger
    )

    let recovered = try await engine.recoverInterrupted(session)

    #expect(recovered == expected)
    #expect(merger.requests.count == 1)
    #expect(await files.committedContinuationIDs == [session.meetingID])
  }

  @Test("Ending reconciles continuation audio left by a failed resume")
  func finishInterruptedReconcilesFailedResume() async throws {
    let session = RecordingSession.fixture()
    let original = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: URL(fileURLWithPath: "/authorized/meeting"),
      recordingURL: URL(fileURLWithPath: "/authorized/meeting/recording.m4a")
    )
    let continuation = RecordingContinuationReservation(
      meetingID: session.meetingID,
      originalRecordingURL: original.recordingURL,
      continuationURL: original.directoryURL.appending(path: ".continuation.m4a"),
      candidateURL: original.directoryURL.appending(path: ".candidate.m4a")
    )
    let files = RecordingFilesStub(
      recoveredReservation: original,
      continuationReservation: continuation,
      captureEventFailures: 1
    )
    let merger = AudioMergerSpy()
    let expected = RecordedAudio(
      durationSeconds: 35,
      packetCount: 1_600,
      byteCount: 120_000
    )
    let engine = makeEngine(
      files: files,
      drivers: DriverFactorySpy(),
      validator: ValidatorStub(audio: expected),
      merger: merger
    )

    _ = try await engine.recoverInterrupted(session)
    await #expect(throws: RecordingError.recordingWriteFailed) {
      _ = try await engine.resumeInterrupted(session)
    }
    let finished = try await engine.finishInterrupted(session)

    #expect(finished == expected)
    #expect(merger.requests.count == 1)
    #expect(await files.committedContinuationIDs == [session.meetingID])
    #expect(await files.finishedIDs == [session.meetingID])
  }

  @Test("Transient validation failure remains retryable")
  func interruptedRecoveryPreservesTransientValidationFailure() async {
    let session = RecordingSession.fixture()
    let reservation = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: URL(fileURLWithPath: "/authorized/meeting"),
      recordingURL: URL(fileURLWithPath: "/authorized/meeting/recording.m4a")
    )
    let files = RecordingFilesStub(recoveredReservation: reservation)
    let engine = makeEngine(
      files: files,
      drivers: DriverFactorySpy(),
      validator: ValidatorStub(error: DriverFailure())
    )

    await #expect(throws: RecordingError.recordingWriteFailed) {
      _ = try await engine.recoverInterrupted(session)
    }
    #expect(await files.finishedIDs.isEmpty)
    #expect(await files.abandonedIDs.isEmpty)
  }

  @Test("A truncated local m4a clears the interrupted recording lock")
  func interruptedRecoveryRejectsTruncatedLocalM4A() async throws {
    let temporary = TemporaryAudioFile()
    try Data([
      0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
      0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00,
      0x4D, 0x34, 0x41, 0x20, 0x6D, 0x70, 0x34, 0x32,
    ]).write(to: temporary.url)
    let session = RecordingSession.fixture()
    let reservation = RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: temporary.url.deletingLastPathComponent(),
      recordingURL: temporary.url
    )
    let files = RecordingFilesStub(recoveredReservation: reservation)
    let engine = makeEngine(
      files: files,
      drivers: DriverFactorySpy(),
      validator: AVRecordedAudioValidator()
    )

    let result = try await engine.recoverInterrupted(session)

    #expect(result == nil)
    #expect(await files.finishedIDs.isEmpty)
    #expect(await files.abandonedIDs == [session.meetingID])
  }

  @Test("Unspecified and permission errors are not definitive content failures")
  func validatorPreservesNonContentErrors() {
    #expect(
      !AVRecordedAudioValidator.isDefinitiveContentFailure(
        kAudioFileUnspecifiedError
      )
    )
    #expect(
      !AVRecordedAudioValidator.isDefinitiveContentFailure(
        kAudioFilePermissionsError
      )
    )
    #expect(
      AVRecordedAudioValidator.isDefinitiveContentFailure(
        kAudioFileInvalidFileError
      )
    )
  }

  @Test("Invalid audio remains unpublished and cannot finish")
  func invalidAudioDoesNotPublishMeeting() async throws {
    let files = RecordingFilesStub()
    let drivers = DriverFactorySpy()
    let engine = makeEngine(
      files: files,
      drivers: drivers,
      validator: ValidatorStub(
        audio: RecordedAudio(
          durationSeconds: 0,
          packetCount: 0,
          byteCount: 32
        )
      )
    )
    let session = RecordingSession.fixture()
    _ = try await engine.start(session)

    await #expect(throws: RecordingError.invalidRecordedAudio) {
      _ = try await engine.stop(meetingID: session.meetingID)
    }

    #expect(await files.finishedIDs.isEmpty)
    #expect(await files.abandonedIDs == [session.meetingID])
    _ = try await engine.start(.fixture(id: UUID()))
  }

  @Test("AVAudioRecorder refuses to replace an existing destination")
  func recorderProtectsExistingDestination() async throws {
    let temporary = TemporaryAudioFile()
    let sentinel = Data("existing".utf8)
    try sentinel.write(to: temporary.url)
    let driver = AVAudioRecorderDriver()

    await #expect(throws: RecordingError.captureCouldNotStart) {
      _ = try await driver.start(at: temporary.url)
    }
    #expect(try Data(contentsOf: temporary.url) == sentinel)
  }

  @Test("AVAudioRecorder driver stops after first-write timeout")
  func recorderStopsAfterWriteTimeout() async {
    let recorder = SystemRecorderDouble(currentTime: 1)
    let driver = AVAudioRecorderDriver(
      makeRecorder: { _ in recorder },
      byteCount: { _ in 100 },
      firstWriteTimeout: .milliseconds(2)
    )
    let url = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID().uuidString).m4a"
    )

    await #expect(throws: RecordingError.recordingWriteFailed) {
      _ = try await driver.start(at: url)
    }

    #expect(recorder.stopCount == 1)
  }

  @Test("Cancelling AVAudioRecorder start stops the system recorder")
  func recorderCancellationStopsSystemRecorder() async {
    let recorder = SystemRecorderDouble(currentTime: 0)
    let driver = AVAudioRecorderDriver(
      makeRecorder: { _ in recorder },
      byteCount: { _ in 0 },
      firstWriteTimeout: .seconds(5)
    )
    let url = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID().uuidString).m4a"
    )
    let task = Task {
      try await driver.start(at: url)
    }
    while !recorder.didRecord {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(recorder.stopCount == 1)
  }

  @Test("The AV validator rejects an empty m4a")
  func validatorRejectsEmptyFile() throws {
    let temporary = TemporaryAudioFile()
    try Data().write(to: temporary.url)

    #expect(throws: RecordingError.invalidRecordedAudio) {
      _ = try AVRecordedAudioValidator().validate(temporary.url)
    }
  }

  @Test("The AV validator reads duration, packets, and bytes from an m4a")
  func validatorReadsPlayableM4A() throws {
    let temporary = TemporaryAudioFile()
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    do {
      let file = try AVAudioFile(
        forWriting: temporary.url,
        settings: settings
      )
      let format = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 44_100,
          channels: 1
        )
      )
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: 44_100
        )
      )
      buffer.frameLength = 44_100
      if let samples = buffer.floatChannelData?[0] {
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
      }
      try file.write(from: buffer)
    }

    let audio = try AVRecordedAudioValidator().validate(temporary.url)

    #expect(audio.durationSeconds > 0.9)
    #expect(audio.packetCount > 0)
    #expect(audio.byteCount > 0)
  }

  @Test("The AV merger produces one playable file containing both recordings")
  func mergerProducesPlayableCombinedM4A() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let originalURL = directory.appending(path: "original.m4a")
    let continuationURL = directory.appending(path: "continuation.m4a")
    let candidateURL = directory.appending(path: "candidate.m4a")
    try Self.writeOneSecondM4A(to: originalURL)
    try Self.writeOneSecondM4A(to: continuationURL)

    try await AVRecordedAudioMerger().merge(
      originalURL: originalURL,
      continuationURL: continuationURL,
      candidateURL: candidateURL
    )
    let audio = try AVRecordedAudioValidator().validate(candidateURL)

    #expect(audio.durationSeconds > 1.8)
    #expect(audio.packetCount > 0)
    #expect(audio.byteCount > 0)
  }

  private func makeEngine(
    files: RecordingFilesStub,
    drivers: DriverFactorySpy,
    permission: any MicrophonePermissionAuthorizing = GrantedPermission(),
    validator: any RecordedAudioValidating = ValidatorStub(),
    merger: any RecordedAudioMerging = AudioMergerSpy()
  ) -> AudioCaptureEngine {
    AudioCaptureEngine(
      files: files,
      permission: permission,
      makeRecorder: {
        drivers.make()
      },
      validator: validator,
      merger: merger
    )
  }

  private static func writeOneSecondM4A(to url: URL) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
      )
    )
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 44_100
      )
    )
    buffer.frameLength = 44_100
    if let samples = buffer.floatChannelData?[0] {
      samples.initialize(repeating: 0, count: Int(buffer.frameLength))
    }
    try file.write(from: buffer)
  }
}

private actor SuspendingPermission: MicrophonePermissionAuthorizing {
  private var requested = false
  private var continuation: CheckedContinuation<Bool, Never>?

  func requestPermission() async -> Bool {
    requested = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilRequested() async {
    while !requested {
      await Task.yield()
    }
  }

  func resolve(_ value: Bool) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

private actor RecordingFilesStub: RecordingFileStore {
  private let recoveredReservation: RecordingFileReservation?
  private let continuationReservation: RecordingContinuationReservation?
  private let recoverContinuation: Bool
  private let finishError: (any Error & Sendable)?
  private var captureEventFailures: Int
  private var hasPendingContinuation = false
  private(set) var publishedIDs: [MeetingID] = []
  private(set) var finishedIDs: [MeetingID] = []
  private(set) var abandonedIDs: [MeetingID] = []
  private(set) var cancelledIDs: [MeetingID] = []
  private(set) var captureEvents: [RecordingCaptureEvent] = []
  private(set) var captureEventAttempts = 0
  private(set) var committedContinuationIDs: [MeetingID] = []

  init(
    recoveredReservation: RecordingFileReservation? = nil,
    continuationReservation: RecordingContinuationReservation? = nil,
    recoverContinuation: Bool = false,
    finishError: (any Error & Sendable)? = nil,
    captureEventFailures: Int = 0
  ) {
    self.recoveredReservation = recoveredReservation
    self.continuationReservation = continuationReservation
    self.recoverContinuation = recoverContinuation
    self.finishError = finishError
    self.captureEventFailures = captureEventFailures
  }

  func reserveRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation {
    let root = FileManager.default.temporaryDirectory.appending(
      path: session.meetingID.rawValue.uuidString,
      directoryHint: .isDirectory
    )
    return RecordingFileReservation(
      meetingID: session.meetingID,
      createdAt: session.startedAt,
      directoryURL: root,
      recordingURL: root.appending(path: "recording.m4a")
    )
  }

  func publishRecordingStart(
    _ reservation: RecordingFileReservation,
    startedAt: Date
  ) async throws {
    publishedIDs.append(reservation.meetingID)
  }

  func recoverInterruptedRecording(
    for session: RecordingSession
  ) async throws -> RecordingFileReservation? {
    recoveredReservation
  }

  func reserveRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation {
    guard let continuationReservation else {
      throw RecordingError.recordingWriteFailed
    }
    return continuationReservation
  }

  func recoverRecordingContinuation(
    for session: RecordingSession
  ) async throws -> RecordingContinuationReservation? {
    recoverContinuation || hasPendingContinuation
      ? continuationReservation
      : nil
  }

  func commitRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async throws {
    hasPendingContinuation = false
    committedContinuationIDs.append(reservation.meetingID)
  }

  func cancelRecordingContinuation(
    _ reservation: RecordingContinuationReservation
  ) async {
    hasPendingContinuation = true
  }

  func finishRecording(meetingID: MeetingID) async throws {
    if let finishError {
      throw finishError
    }
    finishedIDs.append(meetingID)
  }

  func recordCaptureEvent(
    _ event: RecordingCaptureEvent,
    meetingID: MeetingID
  ) async throws {
    captureEventAttempts += 1
    if captureEventFailures > 0 {
      captureEventFailures -= 1
      throw RecordingError.recordingWriteFailed
    }
    captureEvents.append(event)
  }

  func recordingCaptureEvents(
    meetingID: MeetingID
  ) async throws -> [RecordingCaptureEvent] {
    captureEvents
  }

  func abandonRecording(meetingID: MeetingID) async {
    abandonedIDs.append(meetingID)
  }

  func cancelRecording(meetingID: MeetingID) async {
    cancelledIDs.append(meetingID)
  }
}

private struct GrantedPermission: MicrophonePermissionAuthorizing {
  func requestPermission() async -> Bool {
    true
  }
}

private final class DriverFactorySpy: @unchecked Sendable {
  private let lock = NSLock()
  private let startError: (any Error)?
  private let capturedFrames: [AudioFrame]
  private let capturedEvents: [RecordingCaptureEvent]
  private var driverCount = 0
  private var stops = 0
  private var starts: [URL] = []

  init(
    startError: (any Error)? = nil,
    frames: [AudioFrame] = [],
    events: [RecordingCaptureEvent] = []
  ) {
    self.startError = startError
    capturedFrames = frames
    capturedEvents = events
  }

  var count: Int {
    lock.withLock { driverCount }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  var startedURLs: [URL] {
    lock.withLock { starts }
  }

  func make() -> any AudioRecorderDriving {
    lock.withLock {
      driverCount += 1
    }
    return DriverStub(
      startError: startError,
      frames: capturedFrames,
      events: capturedEvents,
      didStart: { [weak self] url in
        self?.lock.withLock {
          self?.starts.append(url)
        }
      },
      didStop: { [weak self] in
        self?.lock.withLock {
          self?.stops += 1
        }
      }
    )
  }
}

private final class DriverStub: AudioRecorderDriving, @unchecked Sendable {
  private let startError: (any Error)?
  private let capturedFrames: [AudioFrame]
  private let capturedEvents: [RecordingCaptureEvent]
  private let didStart: @Sendable (URL) -> Void
  private let didStop: @Sendable () -> Void

  init(
    startError: (any Error)?,
    frames: [AudioFrame],
    events: [RecordingCaptureEvent],
    didStart: @escaping @Sendable (URL) -> Void,
    didStop: @escaping @Sendable () -> Void
  ) {
    self.startError = startError
    capturedFrames = frames
    capturedEvents = events
    self.didStart = didStart
    self.didStop = didStop
  }

  func start(at url: URL) async throws -> Date {
    didStart(url)
    if let startError {
      throw startError
    }
    return Date(timeIntervalSince1970: 1_722_470_400)
  }

  func frames() -> AsyncStream<AudioFrame> {
    AsyncStream { continuation in
      for frame in capturedFrames {
        continuation.yield(frame)
      }
      continuation.finish()
    }
  }

  func events() -> AsyncStream<RecordingCaptureEvent> {
    AsyncStream { continuation in
      for event in capturedEvents {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }

  func stop() {
    didStop()
  }
}

private final class AudioMergerSpy: RecordedAudioMerging, @unchecked Sendable {
  struct Request: Equatable {
    let originalURL: URL
    let continuationURL: URL
    let candidateURL: URL
  }

  private let lock = NSLock()
  private var capturedRequests: [Request] = []

  var requests: [Request] {
    lock.withLock { capturedRequests }
  }

  func merge(
    originalURL: URL,
    continuationURL: URL,
    candidateURL: URL
  ) async throws {
    lock.withLock {
      capturedRequests.append(
        Request(
          originalURL: originalURL,
          continuationURL: continuationURL,
          candidateURL: candidateURL
        )
      )
    }
  }
}

private final class SystemRecorderDouble: SystemAudioRecording, @unchecked Sendable {
  private let lock = NSLock()
  private let elapsed: TimeInterval
  private var recordCalls = 0
  private var stops = 0

  init(currentTime: TimeInterval) {
    elapsed = currentTime
  }

  var currentTime: TimeInterval {
    elapsed
  }

  var didRecord: Bool {
    lock.withLock { recordCalls > 0 }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  func prepareToRecord() -> Bool {
    true
  }

  func record() -> Bool {
    lock.withLock {
      recordCalls += 1
    }
    return true
  }

  func stop() {
    lock.withLock {
      stops += 1
    }
  }
}

private struct ValidatorStub: RecordedAudioValidating {
  let audio: RecordedAudio
  let error: (any Error & Sendable)?

  init(
    audio: RecordedAudio = RecordedAudio(
      durationSeconds: 1,
      packetCount: 1,
      byteCount: 1
    ),
    error: (any Error & Sendable)? = nil
  ) {
    self.audio = audio
    self.error = error
  }

  func validate(_ url: URL) throws -> RecordedAudio {
    if let error {
      throw error
    }
    return audio
  }
}

private struct DriverFailure: Error, Sendable {}

private final class TemporaryAudioFile: @unchecked Sendable {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "\(UUID().uuidString).m4a")

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

extension RecordingSession {
  fileprivate static func fixture(id: UUID? = nil) -> Self {
    .init(
      meetingID: MeetingID(rawValue: id ?? UUID()),
      startedAt: Date(timeIntervalSince1970: 1_722_470_400)
    )
  }
}
