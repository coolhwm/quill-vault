import Application

public enum MeetingLibraryState: Equatable, Sendable {
  case idle
  case loading
  case loaded(MeetingLibrarySnapshot)
  case failed(MeetingLibraryRecovery)
}

public enum MeetingLibraryRecovery: Equatable, Sendable {
  case chooseDirectory
  case renewAccess
  case downloadRequired
  case tryAgain
}
