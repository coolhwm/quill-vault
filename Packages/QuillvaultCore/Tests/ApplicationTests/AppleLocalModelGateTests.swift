import Application
import Testing

@Suite("Apple local model gate")
struct AppleLocalModelGateTests {
  @Test("Probe never blocks BYOK and reports a concrete availability")
  func probeDoesNotBlockBYOK() {
    let report = AppleLocalModelGate.probe()
    #expect(report.blocksBYOK == false)
    #expect(!report.detail.isEmpty)
    #expect(
      [
        AppleLocalModelAvailability.available,
        .unavailable,
        .environmentInsufficient,
        .probeFailed,
      ].contains(report.availability)
    )
  }
}
