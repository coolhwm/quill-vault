import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// FileDocument adapter kept separate from the settings view so the view only
/// coordinates the user-initiated export interaction.
struct DiagnosticExportDocument: FileDocument {
  static let readableContentTypes = [UTType.json]

  var data: Data

  init(data: Data = Data()) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
