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

  func testRecordingNoticeStartStatusAndStopAreAccessible() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-ui-test-recording",
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    )

    let start = app.buttons["recording.start"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()

    let consent = app.alerts["Before your first recording"]
    XCTAssertTrue(consent.waitForExistence(timeout: 2))
    consent.buttons["I understand — start"].tap()

    XCTAssertTrue(screen("recording.screen").waitForExistence(timeout: 2))
    XCTAssertTrue(
      screen("recording.interruption.timeline").waitForExistence(timeout: 2)
    )
    let stop = app.buttons["recording.stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 2))
    XCTAssertTrue(stop.isHittable)
    stop.tap()

    XCTAssertTrue(screen("home.screen").waitForExistence(timeout: 2))
    XCTAssertTrue(
      app.staticTexts["Recording saved · Transcript pending"].exists
    )
    XCTAssertTrue(app.buttons["Retry transcript"].exists)
  }

  func testActionButtonColdLaunchUsesTheSharedRecordingWorkflow() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-ui-test-recording",
        "-ui-test-action-button",
      ]
    )

    let consent = app.alerts["Before your first recording"]
    XCTAssertTrue(consent.waitForExistence(timeout: 5))
    consent.buttons["I understand — start"].tap()

    XCTAssertTrue(screen("recording.screen").waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["recording.stop"].isHittable)
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
    if extraArguments.contains("-ui-test-recording") {
      app.launchEnvironment["QUILLVAULT_RECORDING_UI_TEST"] = "1"
    }
    app.launch()
  }

  private func screen(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
