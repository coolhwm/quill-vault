import Foundation

/// The smallest durable contract between a model response and `minutes.md`.
///
/// Models are asked for Markdown, but a compatible provider may still return
/// JSON, fenced JSON, or a little explanatory text around the payload.  This
/// boundary deliberately prefers a readable body over a complete schema.  A
/// missing optional diagram/section is represented by the completeness hint;
/// only empty, unsafe, or unusable output is rejected.
public struct NormalizedMinutesOutput: Equatable, Sendable {
  public let markdown: String
  public let informationMayBeIncomplete: Bool

  public init(markdown: String, informationMayBeIncomplete: Bool) {
    self.markdown = markdown
    self.informationMayBeIncomplete = informationMayBeIncomplete
  }
}

public enum MinutesOutputNormalizer {
  private static let dangerousFragments = [
    "<script",
    "</script",
    "<iframe",
    "<object",
    "<embed",
    "javascript:",
    "vbscript:",
    "data:text/html",
    "onerror=",
    "onload=",
  ]

  private static let mermaidBlockPattern = #"(?is)```\s*mermaid\s*\n?(.*?)\s*```"#
  private static let frontMatterPattern = #"(?s)^---\r?\n.*?\r?\n---\r?\n"#
  private static let timestampRangePattern =
    #"(?<!\w)(\[\s*)(-?\d+(?:\.\d+)?)\s*(?:--|[-–—])\s*(-?\d+(?:\.\d+)?)\s*(\])"#

  /// Returns `nil` when the response cannot provide a safe, meaningful body.
  /// When supplied, `timelineBounds` keeps recoverable anchors inside the source audio.
  public static func normalize(
    _ raw: String,
    timelineBounds: ClosedRange<Double>? = nil
  ) -> NormalizedMinutesOutput? {
    let trimmed =
      raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let payload = jsonPayload(from: trimmed)
    guard payload != nil || !looksLikeUnparseablePayload(trimmed) else {
      return nil
    }
    var body = payload?.body ?? trimmed
    var candidateDiagrams = payload?.diagrams ?? []

    body = body.replacingOccurrences(
      of: frontMatterPattern,
      with: "",
      options: .regularExpression
    )
    let bodyDiagrams = extractMermaidBlocks(from: body)
    if !bodyDiagrams.isEmpty {
      candidateDiagrams.append(contentsOf: bodyDiagrams)
      body = body.replacingOccurrences(
        of: mermaidBlockPattern,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
    }
    body = normalizeTimeRanges(body, timelineBounds: timelineBounds)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !containsUnsafeMarkup(body), isMeaningfulBody(body) else {
      return nil
    }

    var safeDiagrams: [String] = []
    var seen = Set<String>()
    for candidate in candidateDiagrams {
      guard let normalized = normalizeMermaid(candidate),
        seen.insert(normalized).inserted
      else {
        continue
      }
      safeDiagrams.append(normalized)
    }
    for diagram in safeDiagrams {
      body += "\n\n```mermaid\n\(diagram)\n```"
    }

    let hasStructuredSections = containsStructuredSection(body)
    // Missing diagrams is incomplete only when the body also lacks structure.
    // When diagrams were requested but all rejected, mark incomplete.
    let diagramsRejected = !candidateDiagrams.isEmpty && safeDiagrams.isEmpty
    return NormalizedMinutesOutput(
      markdown: body,
      informationMayBeIncomplete:
        diagramsRejected
        || (safeDiagrams.isEmpty && !hasStructuredSections)
        || !hasStructuredSections
    )
  }

  private static func extractMermaidBlocks(from text: String) -> [String] {
    guard
      let expression = try? NSRegularExpression(
        pattern: mermaidBlockPattern,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
      )
    else {
      return []
    }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1,
        let capture = Range(match.range(at: 1), in: text)
      else {
        return nil
      }
      return String(text[capture])
    }
  }

  private static func jsonPayload(from text: String) -> (body: String, diagrams: [String])? {
    var candidates: [String] = []
    if let fenced = capturedGroup(
      pattern: #"(?is)^```\s*(?:json|javascript|text)?\s*\n?(.*?)\s*```$"#,
      in: text,
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) {
      candidates.append(fenced.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    candidates.append(text)
    if let start = text.firstIndex(of: "{"),
      let end = text.lastIndex(of: "}"),
      start < end
    {
      candidates.append(String(text[start...end]))
    }
    if let start = text.firstIndex(of: "["),
      let end = text.lastIndex(of: "]"),
      start < end
    {
      candidates.append(String(text[start...end]))
    }

    var seen = Set<String>()
    for candidate in candidates where seen.insert(candidate).inserted {
      guard let data = candidate.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(
          with: data,
          options: [.fragmentsAllowed]
        )
      else {
        continue
      }
      guard let body = textValue(in: object)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !body.isEmpty
      else {
        continue
      }
      return (body, diagramValues(in: object))
    }
    return nil
  }

  private static func diagramValues(in value: Any) -> [String] {
    var results: [String] = []
    if let single = diagramValue(in: value) {
      results.append(single)
    }
    if let dictionary = value as? [String: Any] {
      if let array = dictionary["diagrams"] as? [Any] {
        for item in array {
          if let text = item as? String {
            results.append(text)
          } else if let nested = diagramValue(in: item) {
            results.append(nested)
          }
        }
      }
    }
    return results
  }

  private static func looksLikeUnparseablePayload(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    if lowercased.range(
      of: #"(?s)^\s*```\s*(?:json|javascript)\b"#,
      options: .regularExpression
    ) != nil {
      return true
    }
    let firstNonWhitespace = text.first { !$0.isWhitespace }
    switch firstNonWhitespace {
    case "{":
      return text.range(
        of: #"^\s*\{\s*[\"A-Za-z_][^{}]*:"#,
        options: .regularExpression
      ) != nil
    case "[":
      return text.range(
        of: #"^\s*\[\s*(?:\{|\")"#,
        options: .regularExpression
      ) != nil
    default:
      return false
    }
  }

  private static func textValue(in value: Any) -> String? {
    if let string = value as? String {
      return string
    }
    if let dictionary = value as? [String: Any] {
      let preferredKeys = [
        "markdown", "summary", "content", "minutes", "text", "overview", "body",
        "description", "title", "headline", "output", "result", "data",
      ]
      for key in preferredKeys {
        if let nested = dictionary[key], let text = textValue(in: nested) {
          return text
        }
      }
      let nonBodyKeys = Set([
        "diagram", "diagramSource", "mermaid", "graph", "flowchart", "nodes", "edges",
        "error", "errors", "status", "code", "message",
      ])
      for key in dictionary.keys.sorted() where !nonBodyKeys.contains(key) {
        if let text = textValue(in: dictionary[key] as Any) {
          return text
        }
      }
    }
    if let array = value as? [Any] {
      let strings = array.compactMap { textValue(in: $0) }
      if !strings.isEmpty {
        return strings.joined(separator: "\n\n")
      }
    }
    return nil
  }

  private static func diagramValue(in value: Any) -> String? {
    if let string = value as? String {
      return string
    }
    if let dictionary = value as? [String: Any] {
      if let generated = deterministicFlowchart(from: dictionary) {
        return generated
      }
      let preferredKeys = [
        "mermaid", "diagram", "diagramSource", "graph", "flowchart",
      ]
      for key in preferredKeys {
        if let nested = dictionary[key], let value = diagramValue(in: nested) {
          return value
        }
      }
      for nested in dictionary.values {
        if nested is [String: Any] || nested is [Any],
          let value = diagramValue(in: nested)
        {
          return value
        }
      }
    }
    if let array = value as? [Any] {
      for nested in array {
        if let value = diagramValue(in: nested) {
          return value
        }
      }
    }
    return nil
  }

  private static func deterministicFlowchart(from dictionary: [String: Any]) -> String? {
    guard let rawNodes = dictionary["nodes"] as? [Any], !rawNodes.isEmpty else {
      return nil
    }
    struct Node {
      let rawID: String
      let label: String
    }
    let nodes = rawNodes.enumerated().compactMap { index, value -> Node? in
      if let string = value as? String {
        let label = safeMermaidLabel(string)
        guard !label.isEmpty else { return nil }
        return Node(rawID: "node-\(index)", label: label)
      }
      guard let node = value as? [String: Any] else { return nil }
      let rawID =
        (node["id"] as? String)
        ?? (node["key"] as? String)
        ?? "node-\(index)"
      let label = safeMermaidLabel(
        (node["label"] as? String)
          ?? (node["name"] as? String)
          ?? rawID
      )
      guard !label.isEmpty else { return nil }
      return Node(rawID: rawID, label: label)
    }
    guard !nodes.isEmpty else { return nil }

    let orderedNodes = nodes.sorted {
      $0.rawID.localizedStandardCompare($1.rawID) == .orderedAscending
    }
    var usedIDs = Set<String>()
    var idByRawID: [String: String] = [:]
    var lines = ["flowchart TD"]
    for (index, node) in orderedNodes.enumerated() {
      let baseID = mermaidIdentifier(node.rawID, fallback: "N\(index + 1)")
      var identifier = baseID
      var suffix = 2
      while usedIDs.contains(identifier) {
        identifier = "\(baseID)_\(suffix)"
        suffix += 1
      }
      usedIDs.insert(identifier)
      idByRawID[node.rawID] = identifier
      lines.append("  \(identifier)[\"\(node.label)\"]")
    }

    if let rawEdges = dictionary["edges"] as? [Any], !rawEdges.isEmpty {
      let edges = rawEdges.compactMap { value -> (String, String, String?)? in
        guard let edge = value as? [String: Any] else { return nil }
        let from = (edge["from"] as? String) ?? (edge["source"] as? String)
        let to = (edge["to"] as? String) ?? (edge["target"] as? String)
        guard let from, let to, let sourceID = idByRawID[from], let targetID = idByRawID[to] else {
          return nil
        }
        let label = (edge["label"] as? String).map(safeMermaidLabel).flatMap {
          $0.isEmpty ? nil : $0
        }
        return (sourceID, targetID, label)
      }
      guard edges.count == rawEdges.count else { return nil }
      for edge in edges.sorted(by: { ($0.0, $0.1, $0.2 ?? "") < ($1.0, $1.1, $1.2 ?? "") }) {
        if let label = edge.2 {
          lines.append("  \(edge.0) -->|\(label)| \(edge.1)")
        } else {
          lines.append("  \(edge.0) --> \(edge.1)")
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func mermaidIdentifier(_ raw: String, fallback: String) -> String {
    let scalars = raw.unicodeScalars.filter { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
    var identifier = String(String.UnicodeScalarView(scalars))
    if identifier.isEmpty || identifier.first?.isNumber == true {
      identifier = fallback + identifier
    }
    return identifier
  }

  private static func safeMermaidLabel(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\\", with: "")
      .replacingOccurrences(of: "\"", with: "'")
      .replacingOccurrences(of: "<", with: "")
      .replacingOccurrences(of: ">", with: "")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalizeMermaid(_ source: String?) -> String? {
    guard var source else { return nil }
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fenced = capturedGroup(
      pattern: mermaidBlockPattern,
      in: source,
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) {
      source = fenced.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !source.isEmpty, source.utf8.count <= 512_000 else {
      return nil
    }
    let lowercased = source.lowercased()
    let blocked = [
      "<", "https://", "http://", "javascript:", "data:", "click ", "%%{",
    ]
    guard !blocked.contains(where: lowercased.contains) else {
      return nil
    }
    let firstLine =
      source
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init) ?? ""
    let supportedHeaders = [
      "flowchart", "graph", "sequencediagram", "statediagram", "classdiagram",
      "erdiagram", "journey", "pie", "gitgraph", "mindmap", "timeline",
      "quadrantchart", "xychart",
    ]
    guard supportedHeaders.contains(where: { firstLine.lowercased().hasPrefix($0) }) else {
      return nil
    }
    return source
  }

  private static func normalizeTimeRanges(
    _ text: String,
    timelineBounds: ClosedRange<Double>?
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: timestampRangePattern) else {
      return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    var result = ""
    var cursor = text.startIndex
    regex.enumerateMatches(in: text, range: range) { match, _, _ in
      guard let match, let matchRange = Range(match.range, in: text) else { return }
      result += text[cursor..<matchRange.lowerBound]
      let replacement: String
      if let startRange = Range(match.range(at: 2), in: text),
        let endRange = Range(match.range(at: 3), in: text),
        let start = Double(text[startRange]),
        let end = Double(text[endRange]),
        start >= 0,
        end > start
      {
        let boundedStart: Double
        let boundedEnd: Double
        if let timelineBounds,
          timelineBounds.lowerBound.isFinite,
          timelineBounds.upperBound.isFinite,
          timelineBounds.upperBound >= timelineBounds.lowerBound
        {
          boundedStart = min(
            max(start, timelineBounds.lowerBound),
            timelineBounds.upperBound
          )
          boundedEnd = min(
            max(end, timelineBounds.lowerBound),
            timelineBounds.upperBound
          )
        } else {
          boundedStart = start
          boundedEnd = end
        }
        replacement =
          boundedEnd > boundedStart
          ? "[\(formatSeconds(boundedStart))–\(formatSeconds(boundedEnd))]"
          : ""
      } else {
        replacement = ""
      }
      result += replacement
      cursor = matchRange.upperBound
    }
    result += text[cursor...]
    return result
  }

  private static func formatSeconds(_ seconds: Double) -> String {
    let rounded = (seconds * 10).rounded() / 10
    if rounded.rounded() == rounded {
      return String(Int(rounded))
    }
    return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
  }

  private static func containsStructuredSection(_ text: String) -> Bool {
    let headingCount = text.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
        count += 1
      }
    }
    if headingCount >= 2 {
      return true
    }
    return text.range(
      of: "决策|结论|行动|待办|风险|问题|decision|conclusion|action|risk|open question|overview",
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  private static func isMeaningfulBody(_ text: String) -> Bool {
    let meaningfulScalars = text.unicodeScalars.filter { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || (scalar.value >= 0x3400 && scalar.value <= 0x9FFF)
    }
    return meaningfulScalars.count >= 2
  }

  private static func containsUnsafeMarkup(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return dangerousFragments.contains(where: lowercased.contains)
      || text.unicodeScalars.contains { $0.value == 0 }
  }

  private static func capturedGroup(
    pattern: String,
    in text: String,
    options: NSRegularExpression.Options = []
  ) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
      let captured = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captured])
  }
}
