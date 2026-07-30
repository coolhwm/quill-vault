import Domain
import Foundation
import Testing

@Suite("Recording capture timeline")
struct RecordingCaptureTimelineTests {
  @Test("Interruption boundaries remain explicit gaps")
  func pairsPersistentBoundaries() {
    let start = Date(timeIntervalSince1970: 1_000)
    let events: [RecordingCaptureEvent] = [
      .interruptionBegan(at: start, reason: .systemInterruption),
      .interruptionEnded(
        at: start.addingTimeInterval(12),
        didResume: true
      ),
      .interruptionBegan(
        at: start.addingTimeInterval(30),
        reason: .processTermination
      ),
    ]

    #expect(
      RecordingCaptureTimeline.gaps(in: events) == [
        RecordingInterruptionGap(
          startedAt: start,
          endedAt: start.addingTimeInterval(12),
          reason: .systemInterruption,
          didResume: true
        ),
        RecordingInterruptionGap(
          startedAt: start.addingTimeInterval(30),
          endedAt: nil,
          reason: .processTermination,
          didResume: false
        ),
      ]
    )
  }
}
