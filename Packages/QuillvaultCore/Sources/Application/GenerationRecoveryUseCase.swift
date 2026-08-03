import Domain

/// Reconciles persisted generation jobs after a process or scene lifecycle
/// transition. The persisted job store remains the source of truth; callers
/// provide the current authoritative directory snapshot used to resume work.
public protocol GenerationRecoveryUseCase: Sendable {
  func reconcile(in snapshot: MeetingLibrarySnapshot) async throws
}
