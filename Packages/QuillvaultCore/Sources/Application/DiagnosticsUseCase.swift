import Domain
import Foundation

public protocol DiagnosticsUseCase: Sendable {
  func preview() async throws -> DiagnosticPreview
  func export() async throws -> DiagnosticExport
}

public actor DiagnosticsWorkflow: DiagnosticsUseCase {
  private let store: any DiagnosticStore
  private let now: @Sendable () -> Date

  public init(
    store: any DiagnosticStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.now = now
  }

  public func preview() async throws -> DiagnosticPreview {
    try await store.diagnosticPreview()
  }

  public func export() async throws -> DiagnosticExport {
    let package = try await store.exportPackage()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(
      DiagnosticExportPackage(
        schemaVersion: package.schemaVersion,
        generatedAt: now(),
        retentionDays: package.retentionDays,
        privacy: package.privacy,
        events: package.events,
        performance: package.performance
      )
    )
    guard DiagnosticPrivacyAudit.forbiddenMarkers(in: data).isEmpty else {
      throw DiagnosticStoreError.invalidData
    }
    return DiagnosticExport(data: data)
  }
}
