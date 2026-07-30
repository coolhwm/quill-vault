import Foundation
import Testing

@testable import AudioCapture

@Suite("Audio capture write monitor")
struct AudioCaptureWriteMonitorTests {
  @Test("Recovery succeeds only after a new audio write")
  func confirmsNewWrite() async throws {
    let monitor = AudioCaptureWriteMonitor()
    monitor.recordWriteSuccess()
    let attempt = monitor.beginRecovery()

    monitor.recordWriteSuccess()

    let result = try await monitor.waitForRecoveryWrite(
      attempt,
      timeout: .milliseconds(20),
      pollingInterval: .milliseconds(1)
    )
    #expect(result == .resumed)
  }

  @Test("A post-recovery write failure never reports resumed")
  func reportsWriteFailure() async throws {
    let monitor = AudioCaptureWriteMonitor()
    let attempt = monitor.beginRecovery()
    monitor.recordWriteFailure(RecordingWriteProbeError())

    let result = try await monitor.waitForRecoveryWrite(
      attempt,
      timeout: .milliseconds(20),
      pollingInterval: .milliseconds(1)
    )
    #expect(result == .failed)
  }

  @Test("A newer recovery attempt supersedes stale confirmation")
  func supersedesStaleAttempt() async throws {
    let monitor = AudioCaptureWriteMonitor()
    let staleAttempt = monitor.beginRecovery()
    _ = monitor.beginRecovery()

    let result = try await monitor.waitForRecoveryWrite(
      staleAttempt,
      timeout: .milliseconds(20),
      pollingInterval: .milliseconds(1)
    )
    #expect(result == .superseded)
  }

  @Test("Recovery times out when no new audio is written")
  func timesOutWithoutWrite() async throws {
    let monitor = AudioCaptureWriteMonitor()
    let attempt = monitor.beginRecovery()

    let result = try await monitor.waitForRecoveryWrite(
      attempt,
      timeout: .milliseconds(5),
      pollingInterval: .milliseconds(1)
    )
    #expect(result == .failed)
  }
}

private struct RecordingWriteProbeError: Error {}
