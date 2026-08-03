import Domain
import Foundation

struct ServerSentEventDecoder: Sendable {
  private var buffer = Data()

  mutating func append(_ data: Data) throws -> [String] {
    buffer.append(data)
    var events: [String] = []
    while let boundary = eventBoundary(in: buffer) {
      let eventData = buffer[..<boundary.lowerBound]
      buffer.removeSubrange(..<boundary.upperBound)
      guard
        let event = String(data: eventData, encoding: .utf8)
      else {
        throw AIProviderError.invalidResponse
      }
      let payload =
        event
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> Substring? in
          guard line.hasPrefix("data:") else {
            return nil
          }
          return line.dropFirst(5).drop(while: { $0 == " " })
        }
        .joined(separator: "\n")
      if !payload.isEmpty {
        events.append(payload)
      }
    }
    return events
  }

  private func eventBoundary(
    in data: Data
  ) -> Range<Data.Index>? {
    if let range = data.range(of: Data([10, 10])) {
      return range
    }
    return data.range(of: Data([13, 10, 13, 10]))
  }
}
