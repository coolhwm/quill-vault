import Domain
import Foundation

struct CoordinatedRecordingFileAccess: Sendable {
  private let mutator: any RecordingFileMutating
  private let digest: @Sendable (URL) throws -> String

  init(
    mutator: any RecordingFileMutating,
    digest: @escaping @Sendable (URL) throws -> String
  ) {
    self.mutator = mutator
    self.digest = digest
  }

  func write(
    _ data: Data,
    destinationURL: URL,
    candidateURL: URL
  ) throws {
    do {
      try mutator.writeSynced(data, to: candidateURL)
      var coordinationError: NSError?
      var replacementError: (any Error)?
      NSFileCoordinator().coordinate(
        writingItemAt: destinationURL,
        options: .forReplacing,
        error: &coordinationError
      ) { coordinatedURL in
        do {
          if FileManager.default.fileExists(atPath: coordinatedURL.path) {
            try mutator.replace(
              itemAt: coordinatedURL,
              with: candidateURL,
              backupItemName: nil,
              keepBackup: false
            )
          } else {
            try mutator.move(
              itemAt: candidateURL,
              to: coordinatedURL
            )
          }
        } catch {
          replacementError = error
        }
      }
      if let coordinationError {
        throw coordinationError
      }
      if let replacementError {
        throw replacementError
      }
      guard try readData(at: destinationURL) == data else {
        throw RecordingError.recordingWriteFailed
      }
    } catch {
      try? removeIfPresent(at: candidateURL)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  func create(
    _ data: Data,
    destinationURL: URL,
    candidateURL: URL
  ) throws {
    do {
      try mutator.writeSynced(data, to: candidateURL)
      var coordinationError: NSError?
      var creationError: (any Error)?
      NSFileCoordinator().coordinate(
        writingItemAt: destinationURL,
        options: .forReplacing,
        error: &coordinationError
      ) { coordinatedURL in
        do {
          guard !FileManager.default.fileExists(atPath: coordinatedURL.path)
          else {
            throw RecordingError.captureCouldNotStart
          }
          try mutator.move(
            itemAt: candidateURL,
            to: coordinatedURL
          )
        } catch {
          creationError = error
        }
      }
      if let coordinationError {
        throw coordinationError
      }
      if let creationError {
        throw creationError
      }
      guard try readData(at: destinationURL) == data else {
        throw RecordingError.recordingWriteFailed
      }
    } catch {
      try? removeIfPresent(at: candidateURL)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  func update(
    destinationURL: URL,
    candidateURL: URL,
    transform: (Data) throws -> Data
  ) throws -> Data {
    do {
      var coordinationError: NSError?
      var mutationError: (any Error)?
      var expectedData: Data?
      NSFileCoordinator().coordinate(
        readingItemAt: destinationURL,
        options: [],
        writingItemAt: destinationURL,
        options: .forReplacing,
        error: &coordinationError
      ) { coordinatedReadURL, coordinatedWriteURL in
        do {
          let data = try transform(Data(contentsOf: coordinatedReadURL))
          try mutator.writeSynced(data, to: candidateURL)
          try mutator.replace(
            itemAt: coordinatedWriteURL,
            with: candidateURL,
            backupItemName: nil,
            keepBackup: false
          )
          expectedData = data
        } catch {
          mutationError = error
        }
      }
      if let coordinationError {
        throw coordinationError
      }
      if let mutationError {
        throw mutationError
      }
      guard
        let expectedData,
        try readData(at: destinationURL) == expectedData
      else {
        throw RecordingError.recordingWriteFailed
      }
      return expectedData
    } catch {
      try? removeIfPresent(at: candidateURL)
      throw error as? RecordingError ?? .recordingWriteFailed
    }
  }

  func removeIfPresent(at url: URL) throws {
    var coordinationError: NSError?
    var removalError: (any Error)?
    NSFileCoordinator().coordinate(
      writingItemAt: url,
      options: .forDeleting,
      error: &coordinationError
    ) { coordinatedURL in
      do {
        guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
          return
        }
        try mutator.removeItem(at: coordinatedURL)
      } catch {
        removalError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let removalError {
      throw removalError
    }
  }

  func move(at sourceURL: URL, to destinationURL: URL) throws {
    var coordinationError: NSError?
    var moveError: (any Error)?
    NSFileCoordinator().coordinate(
      writingItemAt: sourceURL,
      options: .forMoving,
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedSourceURL, coordinatedDestinationURL in
      do {
        guard
          FileManager.default.fileExists(atPath: coordinatedSourceURL.path),
          !FileManager.default.fileExists(
            atPath: coordinatedDestinationURL.path
          )
        else {
          throw RecordingError.recordingWriteFailed
        }
        try mutator.move(
          itemAt: coordinatedSourceURL,
          to: coordinatedDestinationURL
        )
      } catch {
        moveError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let moveError {
      throw moveError
    }
  }

  func replaceOrMove(at sourceURL: URL, to destinationURL: URL) throws {
    var coordinationError: NSError?
    var replacementError: (any Error)?
    NSFileCoordinator().coordinate(
      writingItemAt: sourceURL,
      options: .forMoving,
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedSourceURL, coordinatedDestinationURL in
      do {
        guard
          FileManager.default.fileExists(
            atPath: coordinatedSourceURL.path
          )
        else {
          throw RecordingError.recordingWriteFailed
        }
        if FileManager.default.fileExists(
          atPath: coordinatedDestinationURL.path
        ) {
          try mutator.replace(
            itemAt: coordinatedDestinationURL,
            with: coordinatedSourceURL,
            backupItemName: nil,
            keepBackup: false
          )
        } else {
          try mutator.move(
            itemAt: coordinatedSourceURL,
            to: coordinatedDestinationURL
          )
        }
      } catch {
        replacementError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let replacementError {
      throw replacementError
    }
  }

  func readData(at url: URL) throws -> Data {
    var coordinationError: NSError?
    var readError: (any Error)?
    var result: Data?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: [],
      error: &coordinationError
    ) { coordinatedURL in
      do {
        result = try Data(contentsOf: coordinatedURL)
      } catch {
        readError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let readError {
      throw readError
    }
    guard let result else {
      throw RecordingError.recordingWriteFailed
    }
    return result
  }

  func readDigest(at url: URL) throws -> String {
    var coordinationError: NSError?
    var readError: (any Error)?
    var result: String?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: [],
      error: &coordinationError
    ) { coordinatedURL in
      do {
        result = try digest(coordinatedURL)
      } catch {
        readError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let readError {
      throw readError
    }
    guard let result else {
      throw RecordingError.recordingWriteFailed
    }
    return result
  }

  func readModificationDate(at url: URL) throws -> Date {
    var coordinationError: NSError?
    var readError: (any Error)?
    var result: Date?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: [],
      error: &coordinationError
    ) { coordinatedURL in
      do {
        result = try coordinatedURL.resourceValues(
          forKeys: [.contentModificationDateKey]
        ).contentModificationDate
      } catch {
        readError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let readError {
      throw readError
    }
    guard let result else {
      throw RecordingError.recordingWriteFailed
    }
    return result
  }
}
