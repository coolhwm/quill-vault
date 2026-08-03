import Application
import Domain
import Foundation
import Testing

@Suite("Diagnostics")
struct DiagnosticsTests {
  @Test("Correlation and scalar fields are bounded and content-free")
  func boundsAndSanitizesFields() {
    let correlation = DiagnosticCorrelation(
      meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
      jobID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
      stepID: "step/with transcript text\n\u{0000}",
      attemptID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    )
    let event = DiagnosticEvent(
      kind: .networkMetrics,
      correlation: correlation,
      durationMilliseconds: -1,
      statusCode: 999,
      host: "api.example.com/v1",
      model: "minutes-model\nignored",
      errorCode: "provider\nignored"
    )

    #expect(event.correlation.stepID == "stepwithtranscripttext")
    #expect(event.durationMilliseconds == 0)
    #expect(event.statusCode == 599)
    #expect(event.host == nil)
    #expect(event.model == "minutes-modelignored")
    #expect(event.errorCode == "providerignored")
  }

  @Test("Export remains usable for ordinary model names and contains only the whitelist")
  func exportWhitelist() async throws {
    let store = FixtureDiagnosticStore()
    await store.record(
      DiagnosticEvent(
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        kind: .providerStreamEnd,
        correlation: DiagnosticCorrelation(jobID: UUID()),
        durationMilliseconds: 2_345,
        host: "api.example.com",
        model: "minutes-model",
        responseBytes: 120
      )
    )
    let workflow = DiagnosticsWorkflow(
      store: store,
      now: { Date(timeIntervalSince1970: 1_800_000_100) }
    )

    let export = try await workflow.export()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let package = try decoder.decode(
      DiagnosticExportPackage.self,
      from: export.data
    )

    #expect(package.events.count == 1)
    #expect(package.events[0].model == "minutes-model")
    #expect(DiagnosticPrivacyAudit.forbiddenMarkers(in: export.data).isEmpty)
  }

  @Test("Export audit rejects credentials, payloads and private locations")
  func exportAudit() {
    let data = Data(
      #"{"api_key":"secret","requestBody":"full transcript","path":"/private/meeting"}"#
        .utf8
    )

    let findings = DiagnosticPrivacyAudit.forbiddenMarkers(in: data)

    #expect(findings.contains("api_key"))
    #expect(findings.contains("requestbody"))
    #expect(findings.contains("private-location"))
  }

  @Test("Export fails closed when a store returns a credential marker")
  func exportFailsClosed() async {
    let store = FixtureDiagnosticStore(
      package: DiagnosticExportPackage(
        privacy: "Bearer secret must never leave the app",
        events: []
      )
    )
    let workflow = DiagnosticsWorkflow(store: store)

    await #expect(throws: DiagnosticStoreError.invalidData) {
      _ = try await workflow.export()
    }
  }

  @Test("Performance attribution treats a two-minute Provider wait as external")
  func providerWaitAttribution() {
    let sample = DiagnosticLatencySample(
      totalWallClockMilliseconds: 120_000,
      urlSessionTaskMilliseconds: 119_000
    )

    #expect(DiagnosticPerformanceAttribution.appMilliseconds(for: sample) == 1_000)
    #expect(DiagnosticPerformanceAttribution.isWithinAppBudget(sample))
  }

  @Test("Non-backoff request gaps use a P95 budget")
  func nonBackoffGapBudget() {
    let gaps: [(durationMilliseconds: Int, isBackoff: Bool)] = [
      (100, false),
      (200, false),
      (500, false),
      (2_000, true),
    ]

    #expect(
      DiagnosticPerformanceAttribution.nonBackoffGapP95(gaps) == 500
    )
    #expect(
      DiagnosticPerformanceAttribution.maximumNonBackoffGapMilliseconds == 500
    )
  }

  @Test("Export attribution identifies a long Provider wait")
  func exportedProviderAttribution() {
    let correlation = DiagnosticCorrelation(
      jobID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),
      attemptID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
    )
    let events = [
      DiagnosticEvent(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        timestamp: Date(timeIntervalSince1970: 1_000),
        kind: .requestQueued,
        correlation: correlation
      ),
      DiagnosticEvent(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        timestamp: Date(timeIntervalSince1970: 1_120),
        kind: .networkMetrics,
        correlation: correlation,
        durationMilliseconds: 119_000
      ),
      DiagnosticEvent(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        timestamp: Date(timeIntervalSince1970: 1_120),
        kind: .responseCompleted,
        correlation: correlation,
        durationMilliseconds: 120_000
      ),
    ]

    let summary = DiagnosticPerformanceAttribution.summaries(for: events)
    #expect(summary.count == 1)
    #expect(summary[0].providerTaskMilliseconds == 119_000)
    #expect(summary[0].appMilliseconds == 1_000)
    #expect(summary[0].withinAppBudget)
  }
}

private actor FixtureDiagnosticStore: DiagnosticStore {
  private var events: [DiagnosticEvent] = []
  private let packageOverride: DiagnosticExportPackage?

  init(package: DiagnosticExportPackage? = nil) {
    packageOverride = package
  }

  func record(_ event: DiagnosticEvent) async {
    events.append(event)
  }

  func recentEvents(limit: Int) async throws -> [DiagnosticEvent] {
    Array(events.suffix(max(0, limit)))
  }

  func diagnosticPreview() async throws -> DiagnosticPreview {
    DiagnosticPreview(
      eventCount: events.count,
      oldestEventAt: events.map(\.timestamp).min(),
      newestEventAt: events.map(\.timestamp).max()
    )
  }

  func exportPackage() async throws -> DiagnosticExportPackage {
    packageOverride
      ?? DiagnosticExportPackage(events: events)
  }
}
