import Domain

extension GenerationWorkflow: GenerationRecoveryUseCase {
  public func reconcile(in snapshot: MeetingLibrarySnapshot) async throws {
    let candidates = try await resumableSnapshots()
    var firstError: Error?

    for candidate in candidates {
      guard
        candidate.job.state == .pending || candidate.job.state == .running,
        let meeting = snapshot.meetings.first(where: {
          $0.id == candidate.job.meetingID
        })
      else {
        continue
      }

      do {
        _ = try await resume(
          candidate.job.id,
          in: snapshot.directory,
          meeting: meeting
        )
      } catch {
        firstError = firstError ?? error
      }
    }

    if let firstError {
      throw firstError
    }
  }
}
