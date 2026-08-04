import Testing

@testable import Application

@Suite("Meeting heatmap layout")
struct MeetingHeatmapLayoutTests {
  @Test("Default window is about three months with readable cells")
  func defaultWindowAndMinimumCell() {
    #expect(MeetingHeatmapLayout.defaultWeeks == 13)
    #expect(MeetingHeatmapLayout.minimumCellSize >= 10)

    let narrow = MeetingHeatmapLayout.cellSize(availableWidth: 100)
    #expect(narrow >= MeetingHeatmapLayout.minimumCellSize)

    let phone = MeetingHeatmapLayout.cellSize(availableWidth: 350)
    #expect(phone >= 10)
    // 13 weeks at 350pt with spacing 3 → cell > minimum.
    #expect(phone > MeetingHeatmapLayout.minimumCellSize)
  }

  @Test("Total height grows with cell size so adaptive cells are not clipped")
  func heightTracksCellSize() {
    let small = MeetingHeatmapLayout.totalHeight(cellSize: 10)
    let large = MeetingHeatmapLayout.totalHeight(cellSize: 24)
    #expect(large > small)
    // 7 rows of 24pt + gaps must exceed 7*10 layout.
    #expect(large >= 7 * 24)
  }
}
