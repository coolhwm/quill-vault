import Domain
import Foundation

public actor ResilientTranscriptionJobStore: TranscriptionJobStore {
  private let primary: any TranscriptionJobStore
  private let fallbackURL: URL
  private var fallbackJobs: [MeetingID: TranscriptionJob]?

  public init(
    primary: any TranscriptionJobStore,
    fallbackURL: URL
  ) {
    self.primary = primary
    self.fallbackURL = fallbackURL
  }

  public func savePending(_ job: TranscriptionJob) async throws {
    var fallback = try loadFallback()
    fallback[job.meetingID] = job
    try persistFallback(fallback)
    fallbackJobs = fallback

    // The atomic file is the durability backstop. A temporary database
    // failure must not reopen the stop/termination data-loss window.
    do {
      try await primary.savePending(job)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // The atomic fallback remains authoritative until publication.
    }
  }

  public func pendingJobs() async throws -> [TranscriptionJob] {
    let fallback = try loadFallback()
    let primaryJobs: [TranscriptionJob]
    do {
      primaryJobs = try await primary.pendingJobs()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      primaryJobs = []
    }
    var merged = Dictionary(
      uniqueKeysWithValues: primaryJobs.map { ($0.meetingID, $0) }
    )
    for (meetingID, job) in fallback {
      merged[meetingID] = job
    }
    return Array(merged.values)
  }

  public func markPublished(
    meetingID: MeetingID,
    revision: TranscriptRevision
  ) async throws {
    try await primary.markPublished(
      meetingID: meetingID,
      revision: revision
    )
    var fallback = try loadFallback()
    fallback[meetingID] = nil
    try persistFallback(fallback)
    fallbackJobs = fallback
  }

  private func loadFallback() throws -> [MeetingID: TranscriptionJob] {
    if let fallbackJobs {
      return fallbackJobs
    }
    guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
      fallbackJobs = [:]
      return [:]
    }
    let jobs = try JSONDecoder().decode(
      [TranscriptionJob].self,
      from: Data(contentsOf: fallbackURL)
    )
    let indexed = Dictionary(
      uniqueKeysWithValues: jobs.map { ($0.meetingID, $0) }
    )
    fallbackJobs = indexed
    return indexed
  }

  private func persistFallback(
    _ jobs: [MeetingID: TranscriptionJob]
  ) throws {
    try FileManager.default.createDirectory(
      at: fallbackURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(
      jobs.values.sorted {
        $0.meetingID.rawValue.uuidString
          < $1.meetingID.rawValue.uuidString
      }
    )
    try data.write(to: fallbackURL, options: .atomic)
  }
}
