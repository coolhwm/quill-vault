public enum DirectoryAccessError: Error, Equatable, Sendable {
  case bookmarkMissing
  case bookmarkStale
  case permissionDenied
  case directoryMoved
  case itemNotDownloaded
  case unreadableDirectory
  case invalidSelection
  case coordinationFailed
}
