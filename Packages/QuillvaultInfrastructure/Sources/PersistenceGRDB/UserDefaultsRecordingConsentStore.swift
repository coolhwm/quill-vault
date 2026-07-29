import Domain
import Foundation

public actor UserDefaultsRecordingConsentStore: RecordingConsentStore {
  private let defaults: UserDefaults
  private let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = "recordingNoticeAcknowledged"
  ) {
    self.defaults = defaults
    self.key = key
  }

  public func hasAcknowledgedRecordingNotice() async -> Bool {
    defaults.bool(forKey: key)
  }

  public func acknowledgeRecordingNotice() async throws {
    defaults.set(true, forKey: key)
  }
}
