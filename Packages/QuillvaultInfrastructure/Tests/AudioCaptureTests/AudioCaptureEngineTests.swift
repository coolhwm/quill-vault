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

    #expect(throws: (any Error).self) {
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

  private func makeEngine(
    files: RecordingFilesStub,
    drivers: DriverFactorySpy,
    permission: any MicrophonePermissionAuthorizing = GrantedPermission(),
    validator: any RecordedAudioValidating = ValidatorStub()
  ) -> AudioCaptureEngine {
    AudioCaptureEngine(
      files: files,
      permission: permission,
      makeRecorder: {
        drivers.make()
      },
      validator: validator
    )
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
  private(set) var publishedIDs: [MeetingID] = []
  private(set) var finishedIDs: [MeetingID] = []
  private(set) var abandonedIDs: [MeetingID] = []
  private(set) var cancelledIDs: [MeetingID] = []

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

  func finishRecording(meetingID: MeetingID) async throws {
    finishedIDs.append(meetingID)
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
  private var driverCount = 0
  private var stops = 0

  init(
    startError: (any Error)? = nil,
    frames: [AudioFrame] = []
  ) {
    self.startError = startError
    capturedFrames = frames
  }

  var count: Int {
    lock.withLock { driverCount }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  func make() -> any AudioRecorderDriving {
    lock.withLock {
      driverCount += 1
    }
    return DriverStub(
      startError: startError,
      frames: capturedFrames,
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
  private let didStop: @Sendable () -> Void

  init(
    startError: (any Error)?,
    frames: [AudioFrame],
    didStop: @escaping @Sendable () -> Void
  ) {
    self.startError = startError
    capturedFrames = frames
    self.didStop = didStop
  }

  func start(at url: URL) async throws -> Date {
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

  func stop() {
    didStop()
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

  init(
    audio: RecordedAudio = RecordedAudio(
      durationSeconds: 1,
      packetCount: 1,
      byteCount: 1
    )
  ) {
    self.audio = audio
  }

  func validate(_ url: URL) throws -> RecordedAudio {
    audio
  }
}

private struct DriverFailure: Error {}

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
