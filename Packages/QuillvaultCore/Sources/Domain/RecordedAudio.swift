import Foundation

public struct RecordedAudio: Equatable, Sendable {
  public let durationSeconds: Double
  public let packetCount: Int64
  public let byteCount: Int64
  public let fileURL: URL?

  public init(
    durationSeconds: Double,
    packetCount: Int64,
    byteCount: Int64,
    fileURL: URL? = nil
  ) {
    self.durationSeconds = durationSeconds
    self.packetCount = packetCount
    self.byteCount = byteCount
    self.fileURL = fileURL
  }

  public var isValid: Bool {
    durationSeconds > 0 && packetCount > 0 && byteCount > 0
  }
}
