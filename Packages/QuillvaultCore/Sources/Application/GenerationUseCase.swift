import Domain
import Foundation

public protocol GenerationUseCase: Sendable {
  func start(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot

  func regenerate(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool
  ) async throws -> GenerationSnapshot

  func resume(
    _ jobID: UUID,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    replacingExternalMinutes: Bool
  ) async throws -> GenerationSnapshot

  func load(
    meetingID: MeetingID
  ) async throws -> GenerationSnapshot?

  func cancel(_ jobID: UUID) async
}

extension GenerationUseCase {
  public func regenerate(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    try await regenerate(
      in: directory,
      meeting: meeting,
      replacingExternalMinutes: false
    )
  }

  public func resume(
    _ jobID: UUID,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot {
    try await resume(
      jobID,
      in: directory,
      meeting: meeting,
      replacingExternalMinutes: false
    )
  }
}

public enum GenerationWorkflowError: Error, Equatable, Sendable {
  case transcriptNotReady
  case activeJobExists
  case queueFull
  case jobNotFound
  case profileUnavailable
  case externalMinutesChanged
}
