import Foundation

/// Feasibility probe for Apple on-device models. MVP generation remains BYOK.
public enum AppleLocalModelAvailability: String, Equatable, Sendable {
  case available
  case unavailable
  case environmentInsufficient
  case probeFailed
}

public struct AppleLocalModelGateReport: Equatable, Sendable {
  public let availability: AppleLocalModelAvailability
  public let systemVersion: String
  public let isSimulator: Bool
  public let detail: String
  public let blocksBYOK: Bool

  public init(
    availability: AppleLocalModelAvailability,
    systemVersion: String,
    isSimulator: Bool,
    detail: String,
    blocksBYOK: Bool = false
  ) {
    self.availability = availability
    self.systemVersion = systemVersion
    self.isSimulator = isSimulator
    self.detail = detail
    self.blocksBYOK = blocksBYOK
  }
}

public enum AppleLocalModelGate {
  /// Simulator-first feasibility check. Does not enable product generation.
  public static func probe(
    processInfo: ProcessInfo = .processInfo
  ) -> AppleLocalModelGateReport {
    let version = processInfo.operatingSystemVersionString
    #if targetEnvironment(simulator)
      let isSimulator = true
    #else
      let isSimulator = false
    #endif

    // As of MVP, the project cannot depend on a simulator-stable Apple on-device
    // generation API for structured minutes. Record the gate result and keep
    // BYOK as the only product path.
    if isSimulator {
      return AppleLocalModelGateReport(
        availability: .environmentInsufficient,
        systemVersion: version,
        isSimulator: true,
        detail: """
          Simulator cannot stably validate Apple on-device model selection and \
          structured minutes generation for Quillvault MVP. Capability is deferred; \
          BYOK remains the release path.
          """,
        blocksBYOK: false
      )
    }

    return AppleLocalModelGateReport(
      availability: .unavailable,
      systemVersion: version,
      isSimulator: false,
      detail: """
        Apple on-device minutes generation is not productized in this build. \
        Device-side validation remains a future gate and does not block BYOK.
        """,
      blocksBYOK: false
    )
  }
}
