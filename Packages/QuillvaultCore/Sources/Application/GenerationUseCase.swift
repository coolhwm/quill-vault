import Domain
import Foundation

public protocol GenerationUseCase: Sendable {
  func start(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot

  func resume(
    _ jobID: UUID,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationSnapshot

  func load(
    meetingID: MeetingID
  ) async throws -> GenerationSnapshot?

  func cancel(_ jobID: UUID) async
}

public enum GenerationWorkflowError: Error, Equatable, Sendable {
  case transcriptNotReady
  case activeJobExists
  case jobNotFound
  case profileUnavailable
}
