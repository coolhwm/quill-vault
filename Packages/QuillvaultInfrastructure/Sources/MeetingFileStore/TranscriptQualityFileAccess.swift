import Domain
import Foundation

extension MeetingFileStore: TranscriptQualityAccess {
  public func publishOptimized(
    _ revision: TranscriptRevision,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry,
    metadata: TranscriptVersionMetadata
  ) async throws {
    do {
      try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        let originalURL = meetingURL.appending(path: "transcript.md")
        let destinationURL = meetingURL.appending(path: "transcript.optimized.md")
        let candidateURL = meetingURL.appending(
          path: ".transcript.optimized-\(revision.id).tmp"
        )
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
          throw TranscriptQualityAccessError.transcriptUnavailable
        }
        let originalBefore = try coordinatedReadData(at: originalURL)
        let markdown = optimizedMarkdown(for: revision, metadata: metadata)
        let expected = Data(markdown.utf8)
        do {
          try dependencies.fileMutator.writeSynced(expected, to: candidateURL)
          try coordinatedReplaceOptimized(
            candidateURL: candidateURL,
            destinationURL: destinationURL
          )
          guard try coordinatedReadData(at: destinationURL) == expected else {
            throw TranscriptQualityAccessError.publicationFailed
          }
          let originalAfter = try coordinatedReadData(at: originalURL)
          guard originalAfter == originalBefore else {
            throw TranscriptQualityAccessError.publicationFailed
          }
        } catch {
          try? dependencies.fileMutator.removeItem(at: candidateURL)
          throw TranscriptQualityAccessError.publicationFailed
        }
      }
    } catch let error as TranscriptQualityAccessError {
      throw error
    } catch {
      throw TranscriptQualityAccessError.publicationFailed
    }
  }

  public func loadOriginalTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision {
    try await loadTranscriptRevision(
      fileName: "transcript.md",
      in: directory,
      meeting: meeting
    )
  }

  public func loadOptimizedTranscript(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision? {
    do {
      return try await loadTranscriptRevision(
        fileName: "transcript.optimized.md",
        in: directory,
        meeting: meeting
      )
    } catch TranscriptQualityAccessError.transcriptUnavailable {
      return nil
    }
  }

  public func originalTranscriptFingerprint(
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> String? {
    do {
      return try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        let originalURL = meetingURL.appending(path: "transcript.md")
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
          return nil
        }
        let data = try coordinatedReadData(at: originalURL)
        return GenerationInputFingerprint.make(
          String(data: data, encoding: .utf8) ?? ""
        )
      }
    } catch {
      throw TranscriptQualityAccessError.directoryUnavailable
    }
  }

  private func loadTranscriptRevision(
    fileName: String,
    in directory: AuthoritativeDirectory,
    meeting: MeetingIndexEntry
  ) async throws -> TranscriptRevision {
    do {
      return try await withGenerationScope(in: directory) { rootURL in
        let meetingURL = try generationMeetingURL(
          rootURL: rootURL,
          meeting: meeting
        )
        let url = meetingURL.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw TranscriptQualityAccessError.transcriptUnavailable
        }
        let markdown = try coordinatedReadString(at: url)
        let timeline = try MeetingTranscriptMarkdownParser().parse(markdown)
        let locale = frontMatterValue(named: "locale", in: markdown) ?? "und"
        return TranscriptRevision(
          meetingID: meeting.id,
          localeIdentifier: locale,
          timeline: timeline
        )
      }
    } catch let error as TranscriptQualityAccessError {
      throw error
    } catch {
      throw TranscriptQualityAccessError.transcriptUnavailable
    }
  }

  private func coordinatedReplaceOptimized(
    candidateURL: URL,
    destinationURL: URL
  ) throws {
    var coordinationError: NSError?
    var replacementError: (any Error)?
    NSFileCoordinator().coordinate(
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedDestinationURL in
      do {
        if FileManager.default.fileExists(atPath: coordinatedDestinationURL.path) {
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
    if coordinationError != nil {
      throw TranscriptQualityAccessError.publicationFailed
    }
    if replacementError != nil {
      throw TranscriptQualityAccessError.publicationFailed
    }
  }

  private func optimizedMarkdown(
    for revision: TranscriptRevision,
    metadata: TranscriptVersionMetadata
  ) -> String {
    var lines = [
      "---",
      "schemaVersion: 1",
      "revisionID: \(revision.id)",
      "contentFingerprint: \(revision.contentFingerprint)",
      "locale: \(revision.localeIdentifier)",
      "audioDurationSeconds: \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), revision.timeline.audioDurationSeconds))",
      "transcriptVersion: \(metadata.kind.rawValue)",
      "parentVersion: \(metadata.parentKind.rawValue)",
      "qualityStrategyID: \(metadata.strategyID)",
      "qualityStrategyVersion: \(metadata.strategyVersion)",
    ]
    if let modelName = metadata.modelName {
      lines.append("model: \(modelName)")
    }
    lines.append(
      "optimizedAt: \(ISO8601DateFormatter().string(from: metadata.createdAt))"
    )
    lines.append(contentsOf: [
      "---",
      "",
      "# 优化文字记录",
      "",
    ])
    lines.append(
      contentsOf: revision.timeline.segments.map {
        TranscriptAnchorFormatter.line(
          for: TranscriptSegmentCandidate(
            startSeconds: $0.startSeconds,
            endSeconds: $0.endSeconds,
            text: $0.text
          )
        )
      }
    )
    lines.append("")
    return lines.joined(separator: "\n")
  }
}
