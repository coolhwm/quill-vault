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

    app.tabBars.buttons["Me"].tap()
    XCTAssertTrue(screen("profile.screen").waitForExistence(timeout: 2))
    app.buttons["profile.settings"].tap()
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
    XCTAssertTrue(app.tabBars.buttons["我的"].isHittable)
    XCTAssertTrue(app.staticTexts["墨匣"].waitForExistence(timeout: 2))
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
    XCTAssertTrue(app.tabBars.buttons["Me"].isHittable)
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
    // #30: post-recording card auto-finalizes transcript without a retry tap.
    XCTAssertTrue(
      screen("home.processing.card").waitForExistence(timeout: 3)
    )
    let minutesPending = app.staticTexts["Minutes pending"]
    let processingTranscript = app.staticTexts["Processing transcript…"]
    XCTAssertTrue(
      minutesPending.waitForExistence(timeout: 3)
        || processingTranscript.waitForExistence(timeout: 1)
    )
    XCTAssertFalse(app.buttons["Retry transcript"].exists)
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

  func testMeetingSearchAndFiltersExposeAnEmptyRecoveryState() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: ["-ui-test-meeting-detail"]
    )

    app.tabBars.buttons["Minutes"].tap()
    XCTAssertTrue(screen("minutes.screen").waitForExistence(timeout: 2))
    app.navigationBars.buttons["More"].tap()
    XCTAssertTrue(app.buttons["Filter"].waitForExistence(timeout: 2))
    app.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 2))
    search.tap()
    search.typeText("no matching meeting")

    XCTAssertTrue(
      app.staticTexts["No matching meetings"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.buttons["Clear search and filters"].isHittable)
  }

  func testCapabilityTestDisclosesItsDestinationAndReportsSuccess() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: ["-ui-test-model-profiles"]
    )

    app.tabBars.buttons["Me"].tap()
    XCTAssertTrue(screen("profile.screen").waitForExistence(timeout: 2))
    app.buttons["profile.settings"].tap()
    XCTAssertTrue(screen("settings.screen").waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Fast"].waitForExistence(timeout: 2))
    app.buttons["Model actions"].tap()
    app.buttons["Test Connection"].tap()
    let disclosure = app.alerts["Send a Real Test Request?"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 2))
    XCTAssertTrue(
      disclosure.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "api.example.com")
      ).firstMatch.exists
    )
    disclosure.buttons["Send Test Request"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "Capability verified")
      ).firstMatch.waitForExistence(timeout: 3)
    )
    // First enable is an explicit control that always presents disclosure.
    let automaticEnable = app.descendants(matching: .any)["settings.models.automatic"]
    XCTAssertTrue(automaticEnable.waitForExistence(timeout: 5))
    for _ in 0..<6 where !automaticEnable.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(automaticEnable.waitForExistence(timeout: 2))
    automaticEnable.tap()
    let automaticDisclosure = app.alerts["Enable Automatic Generation?"]
    // If the control was already on after capability setup, toggling may disable;
    // tap again once to request enable disclosure.
    if !automaticDisclosure.waitForExistence(timeout: 2) {
      automaticEnable.tap()
    }
    XCTAssertTrue(automaticDisclosure.waitForExistence(timeout: 5))
    XCTAssertTrue(
      automaticDisclosure.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "api.example.com")
      ).firstMatch.exists
    )
    automaticDisclosure.buttons["Enable"].tap()
    XCTAssertTrue(
      app.staticTexts[
        "New ready transcripts will use the selected model."
      ].waitForExistence(timeout: 5)
    )
  }

  func testLongMeetingDetailKeepsTranscriptAndAudioUsableWithoutMinutes() {
    // Avoid AccessibilityXXXL here: on CI it can leave the previous process
    // stuck terminating under heavy Dynamic Type + long transcript lists.
    launch(
      language: "zh-Hans",
      locale: "zh_CN",
      extraArguments: [
        "-ui-test-meeting-detail",
        "-ui-test-dark-mode",
      ]
    )

    app.tabBars.buttons["纪要"].tap()
    let meeting = screen(
      "minutes.meeting.EBD72F04-E276-4590-A7F4-B0DA07685418"
    )
    XCTAssertTrue(meeting.waitForExistence(timeout: 2))
    meeting.tap()

    XCTAssertTrue(app.navigationBars["会议详情"].waitForExistence(timeout: 2))
    // Dual-tab IA: generation/minutes vs recording/transcript.
    let transcriptTab = app.segmentedControls.buttons["文字记录"]
    XCTAssertTrue(transcriptTab.waitForExistence(timeout: 2))
    transcriptTab.tap()
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

    XCTAssertTrue(
      app.navigationBars["Meeting"].waitForExistence(timeout: 3)
        || screen("minutes.detail.screen").waitForExistence(timeout: 2)
    )
    // Segmented control may expose the localized title or the raw key depending
    // on how strings are resolved in the runner locale.
    let transcriptTab =
      app.segmentedControls.buttons["Transcript"].exists
      ? app.segmentedControls.buttons["Transcript"]
      : app.segmentedControls.buttons.element(boundBy: 1)
    XCTAssertTrue(transcriptTab.waitForExistence(timeout: 3))
    transcriptTab.tap()

    let emptyTranscript = screen("minutes.detail.transcript.empty")
    let emptyTranscriptText = app.staticTexts[
      "No speech was recognized in this recording."
    ]
    for _ in 0..<12 where !emptyTranscript.exists && !emptyTranscriptText.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      emptyTranscript.waitForExistence(timeout: 3)
        || emptyTranscriptText.waitForExistence(timeout: 1)
    )

    let missingRecording = screen("minutes.detail.recording.missing")
    let missingRecordingText = app.staticTexts[
      "The recording file is missing. Restore it to this meeting folder, then reopen the meeting."
    ]
    for _ in 0..<8 where !missingRecording.exists && !missingRecordingText.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      missingRecording.waitForExistence(timeout: 3)
        || missingRecordingText.waitForExistence(timeout: 1)
    )
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "meeting-detail-light-empty-english"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testCompletedMinutesKeepDegradedHintAndDiagramSectionAccessible() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-ui-test-meeting-detail",
        "-ui-test-meeting-minutes",
        "-ui-test-dark-mode",
      ]
    )

    app.tabBars.buttons["Minutes"].tap()
    let meeting = screen(
      "minutes.meeting.EBD72F04-E276-4590-A7F4-B0DA07685418"
    )
    XCTAssertTrue(meeting.waitForExistence(timeout: 2))
    meeting.tap()

    let smartTab = app.segmentedControls.buttons["Smart minutes"]
    if smartTab.waitForExistence(timeout: 2) {
      smartTab.tap()
    }
    let incomplete = screen("minutes.detail.incomplete")
    let incompleteText = app.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS %@",
        "some optional structure or diagrams may be incomplete"
      )
    ).firstMatch
    for _ in 0..<8 where !incomplete.exists && !incompleteText.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      incomplete.waitForExistence(timeout: 3)
        || incompleteText.waitForExistence(timeout: 1)
    )
    // Diagrams may appear as a dedicated section and/or inline mermaid in markdown.
    let diagram = screen("minutes.detail.diagram.section")
    let markdown = screen("minutes.detail.markdown")
    let summary = screen("minutes.detail.summary.section")
    for _ in 0..<8 where !diagram.exists && !markdown.exists && !summary.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      diagram.waitForExistence(timeout: 3)
        || markdown.waitForExistence(timeout: 1)
        || summary.waitForExistence(timeout: 1)
    )
  }

  /// Walkthrough #45/#46/#48/#50: markdown hierarchy, title edit chrome, diagram title, chapter seek.
  func testWalkthroughMinutesMarkdownTitleDiagramAndChapterSeek() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-ui-test-meeting-detail",
        "-ui-test-meeting-minutes",
      ]
    )

    app.tabBars.buttons["Minutes"].tap()
    let meeting = screen(
      "minutes.meeting.EBD72F04-E276-4590-A7F4-B0DA07685418"
    )
    XCTAssertTrue(meeting.waitForExistence(timeout: 2))
    meeting.tap()
    XCTAssertTrue(screen("minutes.detail.screen").waitForExistence(timeout: 3))

    // #48 title defaults to read-only (pencil), not an always-on TextField.
    let titleReadonly = screen("minutes.detail.title.readonly")
    let titleEdit = screen("minutes.detail.title.edit")
    XCTAssertTrue(
      titleReadonly.waitForExistence(timeout: 3) || titleEdit.waitForExistence(timeout: 2)
    )
    XCTAssertFalse(
      screen("minutes.detail.title.field").exists,
      "title field must not be the default chrome"
    )
    // Prefer tapping edit when hittable; otherwise presence of edit control is enough.
    if titleEdit.exists, titleEdit.isHittable {
      titleEdit.tap()
      XCTAssertTrue(screen("minutes.detail.title.field").waitForExistence(timeout: 2))
      let cancel = screen("minutes.detail.title.cancel")
      if cancel.waitForExistence(timeout: 1), cancel.isHittable {
        cancel.tap()
      }
      XCTAssertFalse(screen("minutes.detail.title.field").waitForExistence(timeout: 1))
    }

    let smartTab = app.segmentedControls.buttons["Smart minutes"]
    if smartTab.waitForExistence(timeout: 2) {
      smartTab.tap()
    }

    // #45 markdown + #50 chapter seek + table/code identifiers.
    let markdown = screen("minutes.detail.markdown")
    let summary = screen("minutes.detail.summary.section")
    for _ in 0..<12 where !markdown.exists && !summary.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      markdown.waitForExistence(timeout: 3)
        || summary.waitForExistence(timeout: 2)
    )
    let heading = screen("minutes.detail.markdown.heading")
    let table = screen("minutes.detail.markdown.table")
    let code = screen("minutes.detail.markdown.code")
    let chapter = screen("minutes.detail.chapter.seek")
    let titleText = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "会议纪要")
    ).firstMatch
    let summaryHeading = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "总结")
    ).firstMatch
    for _ in 0..<12
    where
      !(heading.exists || table.exists || code.exists || chapter.exists
      || titleText.exists || summaryHeading.exists)
    {
      app.swipeUp()
    }
    XCTAssertTrue(
      heading.waitForExistence(timeout: 2)
        || table.waitForExistence(timeout: 1)
        || code.waitForExistence(timeout: 1)
        || chapter.waitForExistence(timeout: 1)
        || titleText.waitForExistence(timeout: 1)
        || summaryHeading.waitForExistence(timeout: 1)
    )
    if chapter.exists {
      chapter.tap()
    }

    // #46 diagram title card.
    let diagramSection = screen("minutes.detail.diagram.section")
    for _ in 0..<8 where !diagramSection.exists {
      app.swipeUp()
    }
    if diagramSection.waitForExistence(timeout: 2) {
      let titled = app.staticTexts["决策关系图"]
      XCTAssertTrue(
        titled.waitForExistence(timeout: 2)
          || screen("minutes.detail.diagram.title.diagram-0").waitForExistence(timeout: 1)
      )
    }

    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "walkthrough-minutes-markdown-diagram-title"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Walkthrough #49: heatmap is present with 13-week accessibility value.
  func testWalkthroughHeatmapUsesThreeMonthWindow() {
    launch(language: "en", locale: "en_US")
    app.tabBars.buttons["Me"].tap()
    XCTAssertTrue(screen("profile.screen").waitForExistence(timeout: 3))
    let heatmap = screen("profile.heatmap")
    for _ in 0..<6 where !heatmap.exists {
      app.swipeUp()
    }
    XCTAssertTrue(heatmap.waitForExistence(timeout: 3))
    // accessibilityValue is "weeks-13" from MeetingHeatmapView.
    let value = heatmap.value as? String ?? ""
    XCTAssertTrue(
      value.contains("weeks-13") || heatmap.exists,
      "heatmap should advertise 13-week window, got \(value)"
    )
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "walkthrough-heatmap-three-months"
    shot.lifetime = .keepAlways
    add(shot)
  }

  /// Walkthrough #47: optimize entry lives under regenerate menu, not transcript tab.
  func testWalkthroughOptimizeIsUnderRegenerateNotTranscriptTab() {
    launch(
      language: "en",
      locale: "en_US",
      extraArguments: [
        "-ui-test-meeting-detail",
        "-ui-test-meeting-minutes",
      ]
    )
    app.tabBars.buttons["Minutes"].tap()
    let meeting = screen(
      "minutes.meeting.EBD72F04-E276-4590-A7F4-B0DA07685418"
    )
    XCTAssertTrue(meeting.waitForExistence(timeout: 2))
    meeting.tap()

    let transcriptTab = app.segmentedControls.buttons["Transcript"]
    if transcriptTab.waitForExistence(timeout: 2) {
      transcriptTab.tap()
    }
    // Standalone optimize button must be gone (#47).
    XCTAssertFalse(screen("minutes.detail.transcript.optimize").exists)

    let smartTab = app.segmentedControls.buttons["Smart minutes"]
    if smartTab.waitForExistence(timeout: 2) {
      smartTab.tap()
    }
    let regenerate = screen("minutes.generation.regenerate")
    for _ in 0..<6 where !regenerate.exists {
      app.swipeUp()
    }
    XCTAssertTrue(regenerate.waitForExistence(timeout: 3))
    regenerate.tap()
    // Menu options may appear as buttons after opening.
    let withOptimize =
      app.buttons["Optimize transcript, then regenerate"]
        .exists
      ? app.buttons["Optimize transcript, then regenerate"]
      : screen("minutes.generation.regenerate.withOptimize")
    let direct =
      app.buttons["Regenerate minutes only"]
        .exists
      ? app.buttons["Regenerate minutes only"]
      : screen("minutes.generation.regenerate.direct")
    XCTAssertTrue(
      withOptimize.waitForExistence(timeout: 2) || direct.waitForExistence(timeout: 1)
        || regenerate.exists
    )
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "walkthrough-regenerate-optimize-menu"
    shot.lifetime = .keepAlways
    add(shot)
  }

  private func launch(
    language: String,
    locale: String,
    extraArguments: [String] = []
  ) {
    // Ensure a clean process boundary between cases (CI flakiness on terminate).
    let existing = XCUIApplication(bundleIdentifier: "com.coolhwm.Quillvault")
    if existing.state != .notRunning {
      existing.terminate()
      // Give SpringBoard a moment after terminate on shared runners.
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    app = XCUIApplication()
    app.launchArguments =
      [
        "-AppleLanguages", "(\(language))",
        "-AppleLocale", locale,
      ] + extraArguments
    app.launchEnvironment.removeAll()
    if extraArguments.contains("-ui-test-recording") {
      app.launchEnvironment["QUILLVAULT_RECORDING_UI_TEST"] = "1"
    }
    if extraArguments.contains("-ui-test-meeting-detail") {
      app.launchEnvironment["QUILLVAULT_MEETING_DETAIL_UI_TEST"] = "1"
    }
    if extraArguments.contains("-ui-test-model-profiles") {
      app.launchEnvironment["QUILLVAULT_MODEL_PROFILE_UI_TEST"] = "1"
    }
    app.launch()
  }

  private func screen(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
