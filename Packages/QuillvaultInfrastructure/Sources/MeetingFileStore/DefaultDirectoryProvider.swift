import Domain
import Foundation

protocol DefaultDirectoryProviding: Sendable {
  func resolve() async throws -> URL
}

struct ICloudDefaultDirectoryProvider: DefaultDirectoryProviding, @unchecked Sendable {
  private let fileManager: FileManager
  private let containerIdentifier: String?

  init(
    fileManager: FileManager = .default,
    containerIdentifier: String? = nil
  ) {
    self.fileManager = fileManager
    self.containerIdentifier = containerIdentifier
  }

  func resolve() async throws -> URL {
    guard let container = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    else {
      throw DirectoryAccessError.iCloudUnavailable
    }
    let directory =
      container
      .appending(path: "Documents", directoryHint: .isDirectory)
      .appending(path: "Quillvault", directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    } catch {
      throw DirectoryAccessError.permissionDenied
    }
  }
}

struct FixedDefaultDirectoryProvider: DefaultDirectoryProviding {
  let url: URL

  func resolve() async throws -> URL {
    url
  }
}
