import Domain

public protocol MeetingDetailUseCase: Sendable {
  func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail
}

public struct MeetingDetailWorkflow: MeetingDetailUseCase {
  private let access: any MeetingDetailAccess

  public init(access: any MeetingDetailAccess) {
    self.access = access
  }

  public func load(
    directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> MeetingDetail {
    try await access.loadMeetingDetail(in: directory, meeting: meeting)
  }
}
