import Domain
import Foundation

extension MeetingFileStore: GenerationFileAccess {
  public func loadTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationTranscriptSource {
    do {
      let source = try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        // Prefer optimized readability version when present; original remains on disk.
        // publishMinutes must validate against this same preferred source.
        guard let transcriptURL = preferredTranscriptURL(in: meetingURL) else {
          throw GenerationFileError.transcriptUnavailable
        }
        let markdown = try coordinatedReadString(at: transcriptURL)
        let timeline = try MeetingTranscriptMarkdownParser().parse(markdown)
        let locale = frontMatterValue(named: "locale", in: markdown) ?? "und"
        return TranscriptRevision(
          meetingID: meeting.id,
          localeIdentifier: locale,
          timeline: timeline
        )
      }
      return GenerationTranscriptSource(revision: source)
    } catch let error as GenerationFileError {
      throw error
    } catch {
      throw GenerationFileError.transcriptUnavailable
    }
  }

  public func loadMinutesSnapshot(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> GenerationMinutesSnapshot? {
    do {
      return try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        let minutesURL = meetingURL.appending(path: "minutes.md")
        guard FileManager.default.fileExists(atPath: minutesURL.path) else {
          return nil
        }
        let markdown = try coordinatedReadString(at: minutesURL)
        let userEditedRaw = frontMatterValue(
          named: "titleUserEdited",
          in: markdown
        )?
        .lowercased()
        return GenerationMinutesSnapshot(
          contentFingerprint: GenerationInputFingerprint.make(markdown),
          generationJobID: frontMatterValue(named: "generationJobID", in: markdown)
            .flatMap(UUID.init(uuidString:)),
          transcriptRevisionID: frontMatterValue(
            named: "transcriptRevisionID",
            in: markdown
          ),
          transcriptFingerprint: frontMatterValue(
            named: "transcriptFingerprint",
            in: markdown
          ),
          titleUserEdited: userEditedRaw == "true" || userEditedRaw == "1"
        )
      }
    } catch let error as GenerationFileError {
      throw error
    } catch {
      throw GenerationFileError.publicationFailed
    }
  }

  public func publishMinutes(
    _ markdown: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) async throws {
    do {
      try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        // Must match loadTranscript: optimized when present, else original.
        guard let transcriptURL = preferredTranscriptURL(in: meetingURL) else {
          throw GenerationFileError.transcriptUnavailable
        }
        let destinationURL = meetingURL.appending(path: "minutes.md")
        let candidateURL = meetingURL.appending(
          path: ".minutes-\(dependencies.makeUUID().uuidString).tmp"
        )
        let expectedData = Data(markdown.utf8)
        do {
          try dependencies.fileMutator.writeSynced(
            expectedData,
            to: candidateURL
          )
          try replaceGenerationFile(
            candidateURL: candidateURL,
            transcriptURL: transcriptURL,
            destinationURL: destinationURL,
            meetingID: meeting.id,
            expectedTranscriptRevisionID: expectedTranscriptRevisionID,
            expectedTranscriptFingerprint: expectedTranscriptFingerprint,
            expectedExistingMinutesFingerprint: expectedExistingMinutesFingerprint
          )
          guard try coordinatedReadData(at: destinationURL) == expectedData else {
            throw GenerationFileError.publicationFailed
          }
        } catch {
          try? dependencies.fileMutator.removeItem(at: candidateURL)
          throw error
        }
      }
    } catch let error as GenerationFileError {
      throw error
    } catch {
      throw GenerationFileError.publicationFailed
    }
  }

  func withGenerationScope<T>(
    in directory: AuthoritativeDirectory,
    operation: (URL) throws -> T
  ) async throws -> T {
    guard let root = resolvedRoots[directory.id] else {
      throw GenerationFileError.directoryUnavailable
    }
    guard await dependencies.scopeAccess.startAccessing(root.url) else {
      throw GenerationFileError.directoryUnavailable
    }
    guard isDirectory(root.url) else {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw GenerationFileError.directoryUnavailable
    }
    do {
      let result = try operation(root.url)
      await dependencies.scopeAccess.stopAccessing(root.url)
      return result
    } catch {
      await dependencies.scopeAccess.stopAccessing(root.url)
      throw error
    }
  }

  func generationMeetingURL(
    rootURL: URL,
    meeting: MeetingIndexEntry
  ) throws -> URL {
    let relative = meeting.relativeDirectory
    guard
      !relative.isEmpty,
      relative.hasPrefix("meeting-"),
      !relative.contains("/"),
      !relative.contains("\\"),
      relative != ".",
      relative != ".."
    else {
      throw GenerationFileError.meetingUnavailable
    }
    let meetingURL = rootURL.appending(
      path: relative,
      directoryHint: .isDirectory
    )
    guard
      meetingURL.deletingLastPathComponent().standardizedFileURL
        == rootURL.standardizedFileURL,
      isDirectory(meetingURL)
    else {
      throw GenerationFileError.meetingUnavailable
    }
    let manifestURL = meetingURL.appending(path: "meeting.json")
    guard
      let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(
        MeetingManifest.self,
        from: manifestData
      ),
      manifest.schemaVersion == 1,
      manifest.meetingID == meeting.id.rawValue,
      (try? manifest.decodedCreationDate()) != nil
    else {
      throw GenerationFileError.meetingUnavailable
    }
    return meetingURL
  }

  func coordinatedReadString(at url: URL) throws -> String {
    let data = try coordinatedReadData(at: url)
    guard let string = String(data: data, encoding: .utf8)
    else {
      throw GenerationFileError.transcriptUnavailable
    }
    return string
  }

  func coordinatedReadData(at url: URL) throws -> Data {
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
      throw CocoaError(.fileReadUnknown)
    }
    return result
  }

  private func replaceGenerationFile(
    candidateURL: URL,
    transcriptURL: URL,
    destinationURL: URL,
    meetingID: MeetingID,
    expectedTranscriptRevisionID: String,
    expectedTranscriptFingerprint: String,
    expectedExistingMinutesFingerprint: String?
  ) throws {
    var coordinationError: NSError?
    var replacementError: (any Error)?
    NSFileCoordinator().coordinate(
      readingItemAt: transcriptURL,
      options: [],
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedTranscriptURL, coordinatedDestinationURL in
      do {
        let transcriptData = try Data(contentsOf: coordinatedTranscriptURL)
        guard
          let transcriptMarkdown = String(data: transcriptData, encoding: .utf8)
        else {
          throw GenerationFileError.sourceChanged
        }
        let timeline = try MeetingTranscriptMarkdownParser().parse(
          transcriptMarkdown
        )
        let locale =
          frontMatterValue(named: "locale", in: transcriptMarkdown)
          ?? "und"
        let currentRevision = TranscriptRevision(
          meetingID: meetingID,
          localeIdentifier: locale,
          timeline: timeline
        )
        guard
          currentRevision.id == expectedTranscriptRevisionID,
          currentRevision.contentFingerprint == expectedTranscriptFingerprint
        else {
          throw GenerationFileError.sourceChanged
        }

        let destinationExists = FileManager.default.fileExists(
          atPath: coordinatedDestinationURL.path
        )
        let currentFingerprint: String?
        if destinationExists {
          guard
            let currentMarkdown = try String(
              data: Data(contentsOf: coordinatedDestinationURL),
              encoding: .utf8
            )
          else {
            throw GenerationFileError.externalMinutesChanged
          }
          currentFingerprint = GenerationInputFingerprint.make(currentMarkdown)
        } else {
          currentFingerprint = nil
        }
        guard currentFingerprint == expectedExistingMinutesFingerprint else {
          throw GenerationFileError.externalMinutesChanged
        }
        if destinationExists {
          try dependencies.fileMutator.replace(
            itemAt: coordinatedDestinationURL,
            with: candidateURL,
            backupItemName: nil,
            keepBackup: false
          )
        } else {
          try dependencies.fileMutator.move(
            itemAt: candidateURL,
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

  /// Transcript asset used for minutes generation input and publish validation.
  /// Prefers `transcript.optimized.md` when present so load and publish pin the
  /// same revision; falls back to immutable `transcript.md`.
  func preferredTranscriptURL(in meetingURL: URL) -> URL? {
    let optimizedURL = meetingURL.appending(path: "transcript.optimized.md")
    if FileManager.default.fileExists(atPath: optimizedURL.path) {
      return optimizedURL
    }
    let originalURL = meetingURL.appending(path: "transcript.md")
    if FileManager.default.fileExists(atPath: originalURL.path) {
      return originalURL
    }
    return nil
  }

  func frontMatterValue(named name: String, in text: String) -> String? {
    guard text.hasPrefix("---") else {
      return nil
    }
    let prefix = "\(name):"
    guard
      let line = text.split(separator: "\n").dropFirst().prefix(while: {
        $0.trimmingCharacters(in: .whitespaces) != "---"
      }).first(where: {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
      })
    else {
      return nil
    }
    let value = line.trimmingCharacters(in: .whitespaces)
      .dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return value.isEmpty ? nil : value
  }
}
