public struct RecordedAudio: Equatable, Sendable {
  public let durationSeconds: Double
  public let packetCount: Int64
  public let byteCount: Int64

  public init(
    durationSeconds: Double,
    packetCount: Int64,
    byteCount: Int64
  ) {
    self.durationSeconds = durationSeconds
    self.packetCount = packetCount
    self.byteCount = byteCount
  }

  public var isValid: Bool {
    durationSeconds > 0 && packetCount > 0 && byteCount > 0
  }
}
