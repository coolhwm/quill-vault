import Foundation

/// Pure layout math for the profile activity heatmap (walkthrough #49).
public enum MeetingHeatmapLayout {
  public static let defaultWeeks = 13
  public static let daysInWeek = 7
  public static let minimumCellSize: Double = 10
  public static let defaultSpacing: Double = 3
  public static let monthLabelHeight: Double = 14
  public static let legendHeight: Double = 20
  public static let verticalStackSpacing: Double = 4

  public static func cellSize(
    availableWidth: Double,
    weeks: Int = defaultWeeks,
    spacing: Double = defaultSpacing,
    minimum: Double = minimumCellSize
  ) -> Double {
    let count = max(weeks, 1)
    let gaps = spacing * Double(count - 1)
    let raw = floor((availableWidth - gaps) / Double(count))
    return max(minimum, raw)
  }

  public static func totalHeight(
    cellSize: Double,
    spacing: Double = defaultSpacing,
    daysInWeek: Int = daysInWeek
  ) -> Double {
    monthLabelHeight
      + verticalStackSpacing
      + Double(daysInWeek) * cellSize
      + Double(daysInWeek - 1) * spacing
      + verticalStackSpacing
      + legendHeight
  }
}
