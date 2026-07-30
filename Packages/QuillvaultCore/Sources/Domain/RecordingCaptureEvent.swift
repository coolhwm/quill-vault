import Foundation

public enum RecordingInterruptionReason: String, Codable, Equatable, Sendable {
  case systemInterruption
  case routeChange
  case mediaServicesReset
  case processTermination
}

public enum RecordingCaptureEvent: Codable, Equatable, Sendable {
  case interruptionBegan(
    at: Date,
    reason: RecordingInterruptionReason
  )
  case interruptionEnded(
    at: Date,
    didResume: Bool
  )
}

public struct RecordingInterruptionGap: Equatable, Sendable {
  public let startedAt: Date
  public let endedAt: Date?
  public let reason: RecordingInterruptionReason
  public let didResume: Bool

  public init(
    startedAt: Date,
    endedAt: Date?,
    reason: RecordingInterruptionReason,
    didResume: Bool
  ) {
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.reason = reason
    self.didResume = didResume
  }
}

public enum RecordingCaptureTimeline {
  public static func gaps(
    in events: [RecordingCaptureEvent]
  ) -> [RecordingInterruptionGap] {
    var gaps: [RecordingInterruptionGap] = []
    var pending:
      (
        startedAt: Date,
        reason: RecordingInterruptionReason
      )?

    for event in events {
      switch event {
      case .interruptionBegan(let startedAt, let reason):
        if let pending {
          gaps.append(
            RecordingInterruptionGap(
              startedAt: pending.startedAt,
              endedAt: nil,
              reason: pending.reason,
              didResume: false
            )
          )
        }
        pending = (startedAt, reason)
      case .interruptionEnded(let endedAt, let didResume):
        guard let openGap = pending else {
          continue
        }
        gaps.append(
          RecordingInterruptionGap(
            startedAt: openGap.startedAt,
            endedAt: endedAt,
            reason: openGap.reason,
            didResume: didResume
          )
        )
        pending = nil
      }
    }

    if let pending {
      gaps.append(
        RecordingInterruptionGap(
          startedAt: pending.startedAt,
          endedAt: nil,
          reason: pending.reason,
          didResume: false
        )
      )
    }
    return gaps
  }
}
