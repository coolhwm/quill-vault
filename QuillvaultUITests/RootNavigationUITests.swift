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

  func testLongMeetingDetailKeepsTranscriptAndAudioUsableWithoutMinutes() {
    launch(
      language: "zh-Hans",
      locale: "zh_CN",
      extraArguments: [
        "-ui-test-meeting-detail",
        "-ui-test-dark-mode",
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    )

    app.tabBars.buttons["纪要"].tap()
    let meeting = screen(
      "minutes.meeting.EBD72F04-E276-4590-A7F4-B0DA07685418"
    )
    XCTAssertTrue(meeting.waitForExistence(timeout: 2))
    meeting.tap()

    XCTAssertTrue(app.navigationBars["会议详情"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["纪要尚未生成，文字记录和录音仍可使用。"].exists)
    let detailSnapshot = XCTAttachment(
      screenshot: app.screenshot()
    )
    detailSnapshot.name = "meeting-detail-dark-maximum-text"
    detailSnapshot.lifetime = .keepAlways
    add(detailSnapshot)
    let recordingToggle = app.buttons["播放"]
    for _ in 0..<10 where !recordingToggle.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(recordingToggle.isHittable)
    recordingToggle.tap()
    XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 2))
    let transcriptHeading = app.staticTexts["文字记录"]
    for _ in 0..<10 where !transcriptHeading.exists {
      app.swipeUp()
    }
    XCTAssertTrue(transcriptHeading.exists)
    let anchoredSegment = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "[000.0–001.0]")
    ).firstMatch
    for _ in 0..<10 where !anchoredSegment.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(anchoredSegment.isHittable)
    anchoredSegment.tap()
    XCTAssertTrue(app.buttons["暂停"].exists)
  }

  func testEmptyEnglishLightMeetingDetailKeepsIndependentFallbacks() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-ui-test-meeting-detail",
        "-ui-test-meeting-detail-empty",
        "-ui-test-light-mode",
      ]
    )

    app.tabBars.buttons["Minutes"].tap()
    let meeting = screen(
      "minutes.meeting.EBD72F04-E276-4590-A7F4-B0DA07685418"
    )
    XCTAssertTrue(meeting.waitForExistence(timeout: 2))
    meeting.tap()

    XCTAssertTrue(app.navigationBars["Meeting"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["No speech was recognized in this recording."].exists)
    XCTAssertTrue(
      app.staticTexts[
        "The recording file is missing. Restore it to this meeting folder, then reopen the meeting."
      ].exists
    )
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "meeting-detail-light-empty-english"
    attachment.lifetime = .keepAlways
    add(attachment)
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
    if extraArguments.contains("-ui-test-meeting-detail") {
      app.launchEnvironment["QUILLVAULT_MEETING_DETAIL_UI_TEST"] = "1"
    }
    app.launch()
  }

  private func screen(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
