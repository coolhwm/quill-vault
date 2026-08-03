import Domain
import Foundation

/// Versioned, replaceable minutes-generation policy. Application workflows depend
/// only on this interface; concrete prompt text lives with the strategy catalog.
public struct MinutesGenerationStrategy: Equatable, Sendable {
  public let id: String
  public let version: String
  public let systemPrompt: String
  public let userPromptTemplate: String
  public let synthesisSystemPrompt: String
  public let synthesisUserPromptTemplate: String
  public let chunkSystemPrompt: String

  public init(
    id: String,
    version: String,
    systemPrompt: String,
    userPromptTemplate: String,
    synthesisSystemPrompt: String,
    synthesisUserPromptTemplate: String,
    chunkSystemPrompt: String
  ) {
    self.id = id
    self.version = version
    self.systemPrompt = systemPrompt
    self.userPromptTemplate = userPromptTemplate
    self.synthesisSystemPrompt = synthesisSystemPrompt
    self.synthesisUserPromptTemplate = synthesisUserPromptTemplate
    self.chunkSystemPrompt = chunkSystemPrompt
  }

  /// Stable token stored on generation jobs so resume keeps the original policy.
  public var promptVersionToken: String {
    "\(id)@\(version)"
  }

  public func userPrompt(transcriptText: String) -> String {
    userPromptTemplate.replacingOccurrences(
      of: "{{transcript}}",
      with: transcriptText
    )
  }

  public func synthesisUserPrompt(chunkSummaries: String) -> String {
    synthesisUserPromptTemplate.replacingOccurrences(
      of: "{{summaries}}",
      with: chunkSummaries
    )
  }
}

public enum MinutesGenerationStrategyCatalog {
  public static let brief = MinutesGenerationStrategy(
    id: "brief",
    version: "v1",
    systemPrompt: """
      You write concise meeting minutes. Return readable Markdown only. \
      Start with a single H1 title that names the meeting topic (never "会议录音" or "Meeting recording"). \
      Prefer a few short paragraphs and only the most important decisions or action items. \
      Do not invent missing facts.
      """,
    userPromptTemplate: """
      Produce a brief minutes summary in the same language as the transcript. \
      Include: title, 2–4 sentence overview, and key decisions/action items only if clearly present.

      {{transcript}}
      """,
    synthesisSystemPrompt: """
      Merge brief segment notes into one short meeting summary. Readable Markdown only. \
      Start with one H1 topic title. Do not invent facts.
      """,
    synthesisUserPromptTemplate: """
      Merge these segment notes into a brief minutes draft in the same language as the source. \
      Keep title, short overview, and only critical decisions/actions.

      {{summaries}}
      """,
    chunkSystemPrompt: """
      Summarize one transcript segment briefly. Markdown only. Preserve decisions, owners, and open questions. Do not invent details.
      """
  )

  public static let standard = MinutesGenerationStrategy(
    id: "standard",
    version: "v1",
    systemPrompt: """
      You write structured meeting minutes. Return readable Markdown only. \
      Start with a single H1 title that names the meeting topic (never "会议录音" or "Meeting recording"). \
      Include overview, decisions, action items, and open questions when present. \
      Optional mermaid is welcome when relationships are clear. Do not invent missing facts.
      """,
    userPromptTemplate: """
      Produce meeting minutes in the same language as the transcript. \
      Include: title, overview, decisions, action items (owner/due if stated), and open questions when present.

      {{transcript}}
      """,
    synthesisSystemPrompt: """
      Merge segment summaries into coherent meeting minutes. Readable Markdown only. \
      Start with one H1 topic title. Preserve uncertainty instead of inventing facts.
      """,
    synthesisUserPromptTemplate: """
      Merge these ordered segment summaries into one minutes draft in the same language as the source. \
      Include title, overview, decisions, action items and open questions when present.

      {{summaries}}
      """,
    chunkSystemPrompt: """
      Summarize one meeting transcript segment. Return readable Markdown. \
      Preserve important decisions, risks, owners, and open questions. Do not invent details.
      """
  )

  public static let full = MinutesGenerationStrategy(
    id: "full",
    version: "v1",
    systemPrompt: """
      You write complete structured meeting minutes. Return readable Markdown only. \
      Start with a single H1 title that names the meeting topic (never "会议录音" or "Meeting recording"). \
      Prefer: overview, timed sections when useful, key decisions with rationale, action items \
      (owner/due/source quote when stated), risks/open questions, and mermaid diagrams when relationships \
      or process are clearer as graphs. Missing optional structure must not block a readable body.
      """,
    userPromptTemplate: """
      Produce full structured minutes in the same language as the transcript. \
      Include title, overview, section notes with time anchors when helpful, decisions, \
      action items, risks/open questions, and suitable diagrams when content supports them.

      {{transcript}}
      """,
    synthesisSystemPrompt: """
      Merge detailed segment summaries into one complete structured minutes draft. Readable Markdown only. \
      Start with one H1 topic title. Prefer overview, sections, decisions, actions, risks, and diagrams when justified.
      """,
    synthesisUserPromptTemplate: """
      Merge these ordered segment summaries into a full minutes draft in the same language as the source. \
      Include title, overview, sections, decisions, action items, risks/open questions, and diagrams when suitable.

      {{summaries}}
      """,
    chunkSystemPrompt: """
      Summarize one meeting transcript segment in detail. Readable Markdown. \
      Preserve decisions, risks, owners, open questions, and notable quotes. Do not invent details.
      """
  )

  public static let all: [MinutesGenerationStrategy] = [brief, standard, full]

  public static func strategy(forPromptVersionToken token: String) -> MinutesGenerationStrategy {
    let parts = token.split(separator: "@", maxSplits: 1).map(String.init)
    let id = parts.first ?? token
    return all.first(where: { $0.id == id }) ?? standard
  }

  public static func strategy(id: String) -> MinutesGenerationStrategy? {
    all.first(where: { $0.id == id })
  }
}

public struct MinutesTranscriptMetrics: Equatable, Sendable {
  public let characterCount: Int
  public let segmentCount: Int
  public let durationSeconds: Double
  public let uniqueTextRatio: Double

  public init(
    characterCount: Int,
    segmentCount: Int,
    durationSeconds: Double,
    uniqueTextRatio: Double
  ) {
    self.characterCount = characterCount
    self.segmentCount = segmentCount
    self.durationSeconds = durationSeconds
    self.uniqueTextRatio = uniqueTextRatio
  }

  public static func make(from revision: TranscriptRevision) -> Self {
    let texts = revision.timeline.segments.map(\.text)
    let characterCount = texts.reduce(0) { $0 + $1.count }
    let unique = Set(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    let uniqueTextRatio =
      texts.isEmpty ? 0 : Double(unique.count) / Double(texts.count)
    return Self(
      characterCount: characterCount,
      segmentCount: revision.timeline.segments.count,
      durationSeconds: revision.timeline.audioDurationSeconds,
      uniqueTextRatio: uniqueTextRatio
    )
  }
}

public enum MinutesGenerationStrategySelector {
  /// Selects a strategy from transcript length and information density.
  /// Low density (repeated/short segments) prefers a briefer output even when long.
  public static func select(
    metrics: MinutesTranscriptMetrics
  ) -> MinutesGenerationStrategy {
    let isSparse =
      metrics.uniqueTextRatio < 0.45
      || (metrics.segmentCount > 0
        && metrics.characterCount / max(metrics.segmentCount, 1) < 12)

    if metrics.characterCount < 900
      || metrics.durationSeconds < 8 * 60
      || metrics.segmentCount < 12
    {
      return isSparse ? MinutesGenerationStrategyCatalog.brief
        : MinutesGenerationStrategyCatalog.brief
    }

    if metrics.characterCount > 6_000
      || metrics.durationSeconds > 35 * 60
      || metrics.segmentCount > 80
    {
      return isSparse
        ? MinutesGenerationStrategyCatalog.standard
        : MinutesGenerationStrategyCatalog.full
    }

    return isSparse
      ? MinutesGenerationStrategyCatalog.brief
      : MinutesGenerationStrategyCatalog.standard
  }

  public static func select(
    from revision: TranscriptRevision
  ) -> MinutesGenerationStrategy {
    select(metrics: .make(from: revision))
  }
}

public enum MinutesTitleResolver {
  public static let bannedTitles: Set<String> = [
    "会议录音",
    "meeting recording",
    "structured minutes",
    "结构化纪要",
    "minutes",
    "纪要",
    "untitled",
    "无标题",
  ]

  /// Resolves the durable topic title for a minutes document.
  /// - Parameters:
  ///   - markdown: Normalized minutes body (may include an H1).
  ///   - previousTitle: Last published title for this meeting, if any.
  ///   - meetingStartedAt: Used only for deterministic fallbacks.
  public static func resolve(
    markdown: String,
    previousTitle: String?,
    meetingStartedAt: Date
  ) -> String {
    if let extracted = extractTitle(from: markdown), isUsable(extracted) {
      return extracted
    }
    if let previousTitle, isUsable(previousTitle) {
      return previousTitle
    }
    return fallbackTitle(meetingStartedAt: meetingStartedAt)
  }

  public static func extractTitle(from markdown: String) -> String? {
    let lines = markdown
      .replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix("#") else {
        if line.isEmpty {
          continue
        }
        // Stop after preamble once body text starts without a title heading.
        if !line.hasPrefix("---") {
          break
        }
        continue
      }
      let stripped = line
        .replacingOccurrences(
          of: #"^#{1,6}\s*"#,
          with: "",
          options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !stripped.isEmpty {
        return sanitize(stripped)
      }
    }
    return nil
  }

  public static func isUsable(_ title: String) -> Bool {
    let trimmed = sanitize(title)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
      return false
    }
    if bannedTitles.contains(trimmed.lowercased())
      || bannedTitles.contains(trimmed)
    {
      return false
    }
    // Reject pure punctuation / numbers with no letters.
    let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    return !letters.isEmpty
  }

  public static func fallbackTitle(meetingStartedAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return "Meeting \(formatter.string(from: meetingStartedAt))"
  }

  public static func sanitize(_ title: String) -> String {
    title
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
