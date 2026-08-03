import Foundation

/// A bounded timing sample used to separate App work from Provider and system
/// waiting time. All values are local elapsed milliseconds.
public struct DiagnosticLatencySample: Equatable, Sendable {
  public let totalWallClockMilliseconds: Int
  public let urlSessionTaskMilliseconds: Int
  public let explicitBackoffMilliseconds: Int
  public let systemPauseMilliseconds: Int

  public init(
    totalWallClockMilliseconds: Int,
    urlSessionTaskMilliseconds: Int,
    explicitBackoffMilliseconds: Int = 0,
    systemPauseMilliseconds: Int = 0
  ) {
    self.totalWallClockMilliseconds = max(0, totalWallClockMilliseconds)
    self.urlSessionTaskMilliseconds = max(0, urlSessionTaskMilliseconds)
    self.explicitBackoffMilliseconds = max(0, explicitBackoffMilliseconds)
    self.systemPauseMilliseconds = max(0, systemPauseMilliseconds)
  }
}

public enum DiagnosticPerformanceAttribution {
  public static let maximumAppMilliseconds = 10_000
  public static let maximumAppFraction = 0.10
  public static let maximumNonBackoffGapMilliseconds = 500

  public static func appMilliseconds(
    for sample: DiagnosticLatencySample
  ) -> Int {
    max(
      0,
      sample.totalWallClockMilliseconds
        - sample.urlSessionTaskMilliseconds
        - sample.explicitBackoffMilliseconds
        - sample.systemPauseMilliseconds
    )
  }

  public static func appBudgetMilliseconds(
    for totalWallClockMilliseconds: Int
  ) -> Int {
    min(
      maximumAppMilliseconds,
      Int(Double(max(0, totalWallClockMilliseconds)) * maximumAppFraction)
    )
  }

  public static func isWithinAppBudget(
    _ sample: DiagnosticLatencySample
  ) -> Bool {
    appMilliseconds(for: sample)
      <= appBudgetMilliseconds(for: sample.totalWallClockMilliseconds)
  }

  public static func p95(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
    return sorted[min(sorted.count, rank) - 1]
  }

  public static func nonBackoffGapP95(
    _ gaps: [(durationMilliseconds: Int, isBackoff: Bool)]
  ) -> Int? {
    p95(
      gaps
        .filter { !$0.isBackoff }
        .map { max(0, $0.durationMilliseconds) }
    )
  }

  /// A compact, exportable attribution result derived only from diagnostic
  /// events. It lets support distinguish provider/network waiting from App
  /// work without exporting request content.
  public struct Summary: Codable, Equatable, Sendable {
    public let correlation: DiagnosticCorrelation
    public let totalWallClockMilliseconds: Int
    public let providerTaskMilliseconds: Int
    public let explicitBackoffMilliseconds: Int
    public let appMilliseconds: Int
    public let appBudgetMilliseconds: Int
    public let withinAppBudget: Bool

    public init(
      correlation: DiagnosticCorrelation,
      totalWallClockMilliseconds: Int,
      providerTaskMilliseconds: Int,
      explicitBackoffMilliseconds: Int,
      appMilliseconds: Int,
      appBudgetMilliseconds: Int,
      withinAppBudget: Bool
    ) {
      self.correlation = correlation
      self.totalWallClockMilliseconds = max(0, totalWallClockMilliseconds)
      self.providerTaskMilliseconds = max(0, providerTaskMilliseconds)
      self.explicitBackoffMilliseconds = max(0, explicitBackoffMilliseconds)
      self.appMilliseconds = max(0, appMilliseconds)
      self.appBudgetMilliseconds = max(0, appBudgetMilliseconds)
      self.withinAppBudget = withinAppBudget
    }
  }

  public static func summaries(
    for events: [DiagnosticEvent]
  ) -> [Summary] {
    let grouped = Dictionary(grouping: events, by: \.correlation)
    return grouped.map { correlation, events in
      let timestamps = events.map(\.timestamp)
      let intervalMilliseconds: Int
      if let first = timestamps.min(), let last = timestamps.max() {
        intervalMilliseconds = max(0, Int(last.timeIntervalSince(first) * 1_000))
      } else {
        intervalMilliseconds = 0
      }
      let responseDuration =
        events
        .filter { $0.kind == .responseCompleted || $0.kind == .providerStreamEnd }
        .compactMap(\.durationMilliseconds)
        .max() ?? 0
      let total = max(intervalMilliseconds, responseDuration)
      let provider =
        events
        .filter { $0.kind == .networkMetrics }
        .compactMap(\.durationMilliseconds)
        .max() ?? 0
      let backoff =
        events
        .filter { $0.kind == .retryScheduled }
        .compactMap(\.retryAfterMilliseconds)
        .reduce(0, +)
      let sample = DiagnosticLatencySample(
        totalWallClockMilliseconds: total,
        urlSessionTaskMilliseconds: provider,
        explicitBackoffMilliseconds: backoff
      )
      let app = appMilliseconds(for: sample)
      return Summary(
        correlation: correlation,
        totalWallClockMilliseconds: total,
        providerTaskMilliseconds: provider,
        explicitBackoffMilliseconds: backoff,
        appMilliseconds: app,
        appBudgetMilliseconds: appBudgetMilliseconds(
          for: total
        ),
        withinAppBudget: isWithinAppBudget(sample)
      )
    }
    .sorted { lhs, rhs in
      lhs.totalWallClockMilliseconds > rhs.totalWallClockMilliseconds
    }
  }
}
