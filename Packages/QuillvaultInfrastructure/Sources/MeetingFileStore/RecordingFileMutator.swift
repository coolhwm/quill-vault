import Foundation

protocol RecordingFileMutating: Sendable {
  func writeSynced(_ data: Data, to url: URL) throws
  func replace(
    itemAt destinationURL: URL,
    with sourceURL: URL,
    backupItemName: String?,
    keepBackup: Bool
  ) throws
  func move(itemAt sourceURL: URL, to destinationURL: URL) throws
  func removeItem(at url: URL) throws
}

struct FoundationRecordingFileMutator: RecordingFileMutating {
  func writeSynced(_ data: Data, to url: URL) throws {
    guard
      FileManager.default.createFile(
        atPath: url.path,
        contents: nil
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  func replace(
    itemAt destinationURL: URL,
    with sourceURL: URL,
    backupItemName: String?,
    keepBackup: Bool
  ) throws {
    let options: FileManager.ItemReplacementOptions =
      keepBackup ? .withoutDeletingBackupItem : []
    _ = try FileManager.default.replaceItemAt(
      destinationURL,
      withItemAt: sourceURL,
      backupItemName: backupItemName,
      options: options
    )
  }

  func move(itemAt sourceURL: URL, to destinationURL: URL) throws {
    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
  }

  func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }
}
