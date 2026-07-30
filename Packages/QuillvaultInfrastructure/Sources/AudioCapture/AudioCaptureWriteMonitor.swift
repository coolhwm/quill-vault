import Foundation

final class AudioCaptureWriteMonitor: @unchecked Sendable {
  struct RecoveryAttempt: Equatable, Sendable {
    fileprivate let generation: UInt64
    fileprivate let writeCount: UInt64
  }

  enum RecoveryConfirmation: Equatable, Sendable {
    case resumed
    case failed
    case superseded
  }

  private let lock = NSLock()
  private var sessionWriteError: (any Error)?
  private var recoveryWriteError: (any Error)?
  private var writeCount: UInt64 = 0
  private var recoveryGeneration: UInt64 = 0

  func recordWriteSuccess() {
    lock.withLock {
      writeCount &+= 1
    }
  }

  func recordWriteFailure(_ error: any Error) {
    lock.withLock {
      sessionWriteError = error
      recoveryWriteError = error
    }
  }

  func status() -> (didWrite: Bool, error: (any Error)?) {
    lock.withLock {
      (writeCount > 0, sessionWriteError)
    }
  }

  func beginRecovery() -> RecoveryAttempt {
    lock.withLock {
      recoveryGeneration &+= 1
      recoveryWriteError = nil
      return RecoveryAttempt(
        generation: recoveryGeneration,
        writeCount: writeCount
      )
    }
  }

  func waitForRecoveryWrite(
    _ attempt: RecoveryAttempt,
    timeout: Duration,
    pollingInterval: Duration
  ) async throws -> RecoveryConfirmation {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      try Task.checkCancellation()
      if let result = recoveryConfirmation(for: attempt) {
        return result
      }
      try await Task.sleep(for: pollingInterval)
    }
    return recoveryConfirmation(for: attempt) ?? .failed
  }

  private func recoveryConfirmation(
    for attempt: RecoveryAttempt
  ) -> RecoveryConfirmation? {
    lock.withLock {
      guard attempt.generation == recoveryGeneration else {
        return .superseded
      }
      if recoveryWriteError != nil {
        return .failed
      }
      if writeCount > attempt.writeCount {
        return .resumed
      }
      return nil
    }
  }
}
