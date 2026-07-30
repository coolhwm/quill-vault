import Domain

public enum RecordingQuickStartAttention: Equatable, Sendable {
  case recordingNotice
  case microphonePermission
  case authoritativeDirectory(AuthoritativeDirectoryRecovery)
  case insufficientStorage
  case retry
}

public enum RecordingQuickStartOutcome: Equatable, Sendable {
  case started(RecordingSnapshot)
  case alreadyActive(RecordingSnapshot)
  case requiresInterruptedDecision(RecordingSnapshot)
  case requiresAppAttention(RecordingQuickStartAttention)
  case alreadyStarting
  case cancelled
}

public protocol RecordingQuickStartUseCase: Sendable {
  func restore() async -> RecordingQuickStartOutcome?
  func start() async -> RecordingQuickStartOutcome
  func startNewAfterInterruption() async -> RecordingQuickStartOutcome
}

public actor RecordingQuickStartWorkflow: RecordingQuickStartUseCase {
  private enum Operation {
    case restoring
    case starting
  }

  private let recording: any RecordingUseCase
  private let directory: any AuthoritativeDirectoryUseCase
  private var operation: Operation?
  private var nextWaiterID: UInt64 = 0
  private var operationWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]

  public init(
    recording: any RecordingUseCase,
    directory: any AuthoritativeDirectoryUseCase
  ) {
    self.recording = recording
    self.directory = directory
  }

  public func restore() async -> RecordingQuickStartOutcome? {
    guard beginOperation(.restoring) else {
      return .alreadyStarting
    }
    defer {
      endOperation()
    }

    do {
      guard let restored = try await recording.restore() else {
        return nil
      }
      return outcome(for: restored)
    } catch is CancellationError {
      return .cancelled
    } catch let error as RecordingError {
      return outcome(for: error)
    } catch {
      return .requiresAppAttention(.retry)
    }
  }

  public func start() async -> RecordingQuickStartOutcome {
    if operation == .restoring {
      do {
        try await waitForCurrentOperation()
        try Task.checkCancellation()
      } catch {
        return .cancelled
      }
      return await start()
    }
    guard beginOperation(.starting) else {
      return .alreadyStarting
    }
    defer {
      endOperation()
    }

    return await startUnlocked(checkExistingRecording: true)
  }

  public func startNewAfterInterruption() async
    -> RecordingQuickStartOutcome
  {
    if operation == .restoring {
      do {
        try await waitForCurrentOperation()
        try Task.checkCancellation()
      } catch {
        return .cancelled
      }
      return await startNewAfterInterruption()
    }
    guard beginOperation(.starting) else {
      return .alreadyStarting
    }
    defer {
      endOperation()
    }

    do {
      guard
        let restored = try await recording.restore(),
        case .interrupted = restored.activity
      else {
        return .requiresAppAttention(.retry)
      }
      _ = try await recording.finishInterrupted()
    } catch is CancellationError {
      return .cancelled
    } catch let error as RecordingError {
      return outcome(for: error)
    } catch {
      return .requiresAppAttention(.retry)
    }

    return await startUnlocked(checkExistingRecording: false)
  }

  private func startUnlocked(
    checkExistingRecording: Bool
  ) async -> RecordingQuickStartOutcome {
    do {
      guard try await directory.restore() != nil else {
        return .requiresAppAttention(
          .authoritativeDirectory(.chooseDirectory)
        )
      }

      if checkExistingRecording,
        let restored = try await recording.restore()
      {
        return outcome(for: restored)
      }

      return .started(try await recording.start())
    } catch is CancellationError {
      return .cancelled
    } catch let error as DirectoryAccessError {
      return .requiresAppAttention(
        .authoritativeDirectory(error.recovery)
      )
    } catch let error as RecordingError {
      if error == .alreadyRecording {
        return await restoreAfterCompetingStart()
      }
      return outcome(for: error)
    } catch {
      return .requiresAppAttention(.retry)
    }
  }

  private func restoreAfterCompetingStart() async
    -> RecordingQuickStartOutcome
  {
    do {
      if let restored = try await recording.restore() {
        return outcome(for: restored)
      }
      return .requiresAppAttention(.retry)
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .requiresAppAttention(.retry)
    }
  }

  private func beginOperation(_ requested: Operation) -> Bool {
    guard operation == nil else {
      return false
    }
    operation = requested
    return true
  }

  private func endOperation() {
    operation = nil
    let waiters = operationWaiters.values
    operationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: ())
    }
  }

  private func waitForCurrentOperation() async throws {
    guard operation != nil else {
      return
    }
    try Task.checkCancellation()
    let waiterID = nextWaiterID
    nextWaiterID &+= 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard operation != nil else {
          continuation.resume(returning: ())
          return
        }
        operationWaiters[waiterID] = continuation
      }
      try Task.checkCancellation()
    } onCancel: {
      Task {
        await self.cancelWaiter(waiterID)
      }
    }
  }

  private func cancelWaiter(_ waiterID: UInt64) {
    operationWaiters.removeValue(forKey: waiterID)?.resume(
      throwing: CancellationError()
    )
  }

  private func outcome(
    for snapshot: RecordingSnapshot
  ) -> RecordingQuickStartOutcome {
    switch snapshot.activity {
    case .recording, .finishing:
      .alreadyActive(snapshot)
    case .interrupted:
      .requiresInterruptedDecision(snapshot)
    }
  }

  private func outcome(
    for error: RecordingError
  ) -> RecordingQuickStartOutcome {
    switch error {
    case .recordingConsentRequired:
      .requiresAppAttention(.recordingNotice)
    case .microphonePermissionDenied:
      .requiresAppAttention(.microphonePermission)
    case .authoritativeDirectoryUnavailable:
      .requiresAppAttention(.authoritativeDirectory(.renewAccess))
    case .insufficientStorage:
      .requiresAppAttention(.insufficientStorage)
    case .alreadyRecording, .captureCouldNotStart, .recordingWriteFailed,
      .invalidRecordedAudio, .transcriptionFailed,
      .unsupportedTranscriptionLocale, .speechAssetsUnavailable,
      .transcriptPublicationFailed, .statePersistenceFailed,
      .noActiveRecording:
      .requiresAppAttention(.retry)
    }
  }
}
