import XCTest

@MainActor
final class RootNavigationUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testUserCanVisitEveryTopLevelProductArea() {
    launch(language: "en", locale: "en_US")

    XCTAssertTrue(screen("home.screen").waitForExistence(timeout: 5))

    app.tabBars.buttons["Minutes"].tap()
    XCTAssertTrue(screen("minutes.screen").waitForExistence(timeout: 2))

    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(screen("settings.screen").waitForExistence(timeout: 2))

    app.tabBars.buttons["Home"].tap()
    XCTAssertTrue(screen("home.screen").waitForExistence(timeout: 2))
  }

  func testChineseNavigationUsesTheSameThreeAccessibleEntries() {
    launch(language: "zh-Hans", locale: "zh_CN")

    XCTAssertTrue(screen("home.screen").waitForExistence(timeout: 5))
    XCTAssertEqual(app.tabBars.buttons.count, 3)
    XCTAssertTrue(app.tabBars.buttons["首页"].isHittable)
    XCTAssertTrue(app.tabBars.buttons["纪要"].isHittable)
    XCTAssertTrue(app.tabBars.buttons["设置"].isHittable)
  }

  func testDarkAppearanceAndAccessibilityTextKeepNavigationUsable() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-AppleInterfaceStyle", "Dark",
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    )

    XCTAssertTrue(screen("home.screen").waitForExistence(timeout: 5))
    XCTAssertEqual(app.tabBars.buttons.count, 3)
    XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)
    XCTAssertTrue(app.tabBars.buttons["Minutes"].isHittable)
    XCTAssertTrue(app.tabBars.buttons["Settings"].isHittable)
  }

  private func launch(
    language: String,
    locale: String,
    extraArguments: [String] = []
  ) {
    app = XCUIApplication()
    app.launchArguments =
      [
        "-AppleLanguages", "(\(language))",
        "-AppleLocale", locale,
      ] + extraArguments
    app.launch()
  }

  private func screen(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
