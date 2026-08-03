import Application
import Domain
import Observation

public enum SettingsDirectoryState: Equatable, Sendable {
  case checking
  case recoveryRequired(AuthoritativeDirectoryRecovery)
  case authorized(AuthoritativeDirectory)
}

enum ModelProfileTestState: Equatable, Sendable {
  case testing
  case succeeded(providerDomain: String)
  case failed
}

@MainActor
@Observable
public final class SettingsModel {
  private(set) var directoryState: SettingsDirectoryState = .checking
  private(set) var modelProfiles: [ModelProfile] = []
  private(set) var currentModelProfileID: ModelProfileID?
  private(set) var automaticGeneration = AutomaticGenerationPreferences()
  private(set) var profileTestState: [ModelProfileID: ModelProfileTestState] = [:]
  private(set) var modelProfilesUnavailable = false
  private(set) var diagnosticPreview = DiagnosticPreview(
    eventCount: 0,
    oldestEventAt: nil,
    newestEventAt: nil
  )
  private(set) var diagnosticsUnavailable = false

  private let directory: any AuthoritativeDirectoryUseCase
  private let library: any MeetingLibraryUseCase
  private let modelProfileUseCase: (any ModelProfileUseCase)?
  private let diagnostics: (any DiagnosticsUseCase)?

  public init(
    directory: any AuthoritativeDirectoryUseCase,
    library: any MeetingLibraryUseCase,
    modelProfiles: (any ModelProfileUseCase)? = nil,
    diagnostics: (any DiagnosticsUseCase)? = nil
  ) {
    self.directory = directory
    self.library = library
    modelProfileUseCase = modelProfiles
    self.diagnostics = diagnostics
  }

  public func load() async {
    await loadDirectory()
    await loadModelProfiles()
    await loadDiagnostics()
  }

  public func exportDiagnostics() async throws -> DiagnosticExport {
    guard let diagnostics else {
      throw DiagnosticStoreError.unavailable
    }
    return try await diagnostics.export()
  }

  func saveProfile(_ draft: ModelProfileDraft) async throws {
    guard let modelProfileUseCase else {
      return
    }
    _ = try await modelProfileUseCase.save(draft)
    await loadModelProfiles()
  }

  func selectProfile(_ id: ModelProfileID) async {
    guard let modelProfileUseCase else {
      return
    }
    do {
      try await modelProfileUseCase.select(id)
      await loadModelProfiles()
    } catch {
      modelProfilesUnavailable = true
    }
  }

  func testProfile(_ id: ModelProfileID) async {
    guard let modelProfileUseCase else {
      return
    }
    profileTestState[id] = .testing
    do {
      let capability = try await modelProfileUseCase.test(id)
      profileTestState[id] = .succeeded(
        providerDomain: capability.providerDomain
      )
      await loadModelProfiles()
    } catch {
      profileTestState[id] = .failed
    }
  }

  func setAutomaticGeneration(
    enabled: Bool,
    disclosureAcknowledged: Bool
  ) async {
    guard let modelProfileUseCase else {
      return
    }
    do {
      try await modelProfileUseCase.setAutomaticGeneration(
        enabled: enabled,
        disclosureAcknowledged: disclosureAcknowledged
      )
      await loadModelProfiles()
    } catch {
      modelProfilesUnavailable = true
    }
  }

  func deletionImpact(
    _ id: ModelProfileID
  ) async -> ModelProfileDeletionImpact {
    guard let modelProfileUseCase else {
      return .safe
    }
    return (try? await modelProfileUseCase.deletionImpact(id)) ?? .safe
  }

  func deleteProfile(
    _ id: ModelProfileID,
    confirmed: Bool
  ) async {
    guard let modelProfileUseCase else {
      return
    }
    do {
      try await modelProfileUseCase.delete(id, confirmed: confirmed)
      profileTestState[id] = nil
      await loadModelProfiles()
    } catch {
      modelProfilesUnavailable = true
    }
  }

  private func loadDirectory() async {
    do {
      guard let authorized = try await directory.restore() else {
        directoryState = .recoveryRequired(.chooseDirectory)
        return
      }
      directoryState = .authorized(authorized)
    } catch {
      directoryState = .recoveryRequired(recovery(for: error))
    }
  }

  private func loadModelProfiles() async {
    guard let modelProfileUseCase else {
      return
    }
    do {
      let collection = try await modelProfileUseCase.load()
      modelProfiles = collection.profiles
      currentModelProfileID = collection.currentProfileID
      automaticGeneration = collection.automaticGeneration
      modelProfilesUnavailable = false
    } catch {
      modelProfilesUnavailable = true
    }
  }

  private func loadDiagnostics() async {
    guard let diagnostics else { return }
    do {
      diagnosticPreview = try await diagnostics.preview()
      diagnosticsUnavailable = false
    } catch {
      diagnosticsUnavailable = true
    }
  }

  func selectDirectory(opaqueReference: String) async {
    directoryState = .checking
    do {
      let snapshot = try await library.select(
        AuthoritativeDirectorySelection(
          opaqueReference: opaqueReference
        )
      )
      directoryState = .authorized(snapshot.directory)
    } catch {
      directoryState = .recoveryRequired(recovery(for: error))
    }
  }

  private func recovery(for error: Error) -> AuthoritativeDirectoryRecovery {
    (error as? DirectoryAccessError)?.recovery ?? .tryAgain
  }
}
