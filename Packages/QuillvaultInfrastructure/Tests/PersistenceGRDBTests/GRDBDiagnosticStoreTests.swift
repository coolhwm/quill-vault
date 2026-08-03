import Domain
import Foundation
import PersistenceGRDB
import Testing

@Suite("GRDB diagnostic store")
struct GRDBDiagnosticStoreTests {
  @Test("Keeps a bounded ring and evicts the oldest event")
  func boundedRing() async throws {
    let databaseURL = temporaryDiagnosticDatabaseURL()
    let store = try GRDBDiagnosticStore.open(
      at: databaseURL,
      maximumAge: 60,
      maximumCount: 2,
      now: { Date(timeIntervalSince1970: 1_002) }
    )
    let first = diagnosticEvent(timestamp: 1_000, id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    let second = diagnosticEvent(timestamp: 1_001, id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    let third = diagnosticEvent(timestamp: 1_002, id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")

    await store.record(first)
    await store.record(second)
    await store.record(third)

    let events = try await store.recentEvents()
    let preview = try await store.diagnosticPreview()
    #expect(events.map(\.id) == [third.id, second.id])
    #expect(preview.eventCount == 2)
    #expect(preview.oldestEventAt == second.timestamp)
    #expect(preview.newestEventAt == third.timestamp)
    removeDiagnosticDatabase(at: databaseURL)
  }

  @Test("Evicts events older than the retention window")
  func retentionWindow() async throws {
    let databaseURL = temporaryDiagnosticDatabaseURL()
    let store = try GRDBDiagnosticStore.open(
      at: databaseURL,
      maximumAge: 60,
      maximumCount: 10,
      now: { Date(timeIntervalSince1970: 1_061) }
    )
    let old = diagnosticEvent(timestamp: 1_000, id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
    let current = diagnosticEvent(timestamp: 1_061, id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")

    await store.record(old)
    await store.record(current)

    #expect(try await store.recentEvents().map(\.id) == [current.id])
    removeDiagnosticDatabase(at: databaseURL)
  }

  @Test("Exports redacted events in chronological order")
  func exportOrderAndPrivacy() async throws {
    let databaseURL = temporaryDiagnosticDatabaseURL()
    let store = try GRDBDiagnosticStore.open(
      at: databaseURL,
      now: { Date(timeIntervalSince1970: 2_000) }
    )
    await store.record(
      diagnosticEvent(
        timestamp: 2_000,
        id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
        model: "minutes-model"
      )
    )
    await store.record(
      diagnosticEvent(
        timestamp: 1_000,
        id: "11111111-1111-1111-1111-111111111111",
        model: "minutes-model"
      )
    )

    let package = try await store.exportPackage()
    #expect(
      package.events.map(\.timestamp) == [
        Date(timeIntervalSince1970: 1_000),
        Date(timeIntervalSince1970: 2_000),
      ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(package)
    #expect(DiagnosticPrivacyAudit.forbiddenMarkers(in: data).isEmpty)
    removeDiagnosticDatabase(at: databaseURL)
  }
}

private func diagnosticEvent(
  timestamp: TimeInterval,
  id: String,
  model: String = "test-model"
) -> DiagnosticEvent {
  DiagnosticEvent(
    id: UUID(uuidString: id)!,
    timestamp: Date(timeIntervalSince1970: timestamp),
    kind: .requestQueued,
    correlation: DiagnosticCorrelation(jobID: UUID()),
    host: "api.example.com",
    model: model
  )
}

private func temporaryDiagnosticDatabaseURL() -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "diagnostic-store-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try! FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return directory.appending(path: "diagnostics.sqlite")
}

private func removeDiagnosticDatabase(at url: URL) {
  try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
