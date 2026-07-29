import AppKit
import XCTest

@MainActor
final class SmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchSmokeShowsMainControls() {
        let app = launchApp(scenario: "launchSmoke")

        XCTAssertTrue(element(in: app, identifier: "app.controlBar.toggle").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "app.notesWorkspaceButton").waitForExistence(timeout: 5))
    }

    func testSettingsSmokeShowsCopilotAndTranscriptionPickers() {
        let app = launchApp(scenario: "launchSmoke")
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        // Settings window opens on General tab — verify the tab view exists
        let tabView = element(in: app, identifier: "settings.tabView")
        XCTAssertTrue(tabView.waitForExistence(timeout: 5))

        // Interview Copilot is the primary generation surface in this fork.
        app.toolbars.buttons["Copilot"].click()
        XCTAssertTrue(
            element(in: app, identifier: "settings.copilot.inferenceProviderPicker")
                .waitForExistence(timeout: 5)
        )

        // Navigate to Transcription tab and verify model picker
        app.toolbars.buttons["Transcription"].click()
        XCTAssertTrue(element(in: app, identifier: "settings.transcriptionModelPicker").waitForExistence(timeout: 5))
    }

    func testFirstLaunchEntersMainWorkspaceWithoutLegacyProviderWizard() {
        let app = launchApp(scenario: "wizardSmoke")

        XCTAssertTrue(element(in: app, identifier: "app.controlBar.toggle").waitForExistence(timeout: 5))
        XCTAssertFalse(element(in: app, identifier: "wizard.root").exists)
    }

    func testSessionSmokeShowsEndedBanner() {
        let app = launchApp(scenario: "sessionSmoke")

        let toggle = element(in: app, identifier: "app.controlBar.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertTrue(element(in: app, accessibilityLabel: "暂停收音").waitForExistence(timeout: 5))

        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(in: app, identifier: "app.sessionEndedBanner").waitForExistence(timeout: 5))
    }

    func testSessionSmokeCanSwitchToScratchpadWithoutLosingWorkspace() {
        let app = launchApp(scenario: "sessionSmoke")

        let toggle = element(in: app, identifier: "app.controlBar.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertTrue(
            element(in: app, accessibilityLabel: "暂停收音")
                .waitForExistence(timeout: 5)
        )
        let scratchpadTab = element(in: app, identifier: "app.interviewContext.scratchpadTab")
        XCTAssertTrue(scratchpadTab.waitForExistence(timeout: 5))
        scratchpadTab.click()
        XCTAssertTrue(element(in: app, identifier: "app.scratchpadEditor").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, accessibilityLabel: "暂停收音").exists)
    }

    func testInterviewLensSmokeUsesOnePanelAndKeepsMainBlocksStable() {
        let app = launchApp(scenario: "interviewLensSmoke")
        let toggle = element(in: app, identifier: "app.controlBar.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()

        let answer = element(in: app, identifier: "copilot.interviewLens.answer")
        let followUps = element(in: app, identifier: "copilot.interviewLens.followUps")
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
        XCTAssertTrue(followUps.waitForExistence(timeout: 5))
        XCTAssertFalse(element(in: app, identifier: "copilot.interviewLens.question").exists)
        let micMeter = element(in: app, accessibilityLabel: "Mic 音频电平")
        let systemMeter = element(in: app, accessibilityLabel: "System 音频电平")
        XCTAssertTrue(micMeter.waitForExistence(timeout: 5))
        XCTAssertTrue(systemMeter.waitForExistence(timeout: 5))
        XCTAssertTrue(hasAudibleMeterValue(micMeter))
        XCTAssertTrue(hasAudibleMeterValue(systemMeter))
        XCTAssertTrue(element(in: app, accessibilityLabel: "运行详情").waitForExistence(timeout: 5))
        let asrProvider = element(in: app, identifier: "copilot.asr.provider")
        XCTAssertTrue(asrProvider.waitForExistence(timeout: 5))
        XCTAssertEqual(asrProvider.label, "当前语音识别：腾讯云实时 ASR")
        XCTAssertTrue(element(in: app, identifier: "copilot.actions.regenerate").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "copilot.actions.endInterview").waitForExistence(timeout: 5))
        let moreActions = element(in: app, identifier: "copilot.actions.more")
        XCTAssertTrue(moreActions.waitForExistence(timeout: 5))
        XCTAssertEqual(moreActions.label, "更多面试操作")
        XCTAssertTrue(element(in: app, identifier: "app.interviewContext.transcriptTab").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "app.interviewContext.scratchpadTab").waitForExistence(timeout: 5))
        let mainWindow = app.windows["main"]
        let pauseCapture = element(in: app, accessibilityLabel: "暂停收音")
        let transcriptScrollView = element(in: app, identifier: "transcript.scrollView")
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(pauseCapture.waitForExistence(timeout: 5))
        XCTAssertTrue(transcriptScrollView.waitForExistence(timeout: 5))
        XCTAssertTrue(mainWindow.frame.contains(pauseCapture.frame))
        XCTAssertTrue(mainWindow.frame.contains(transcriptScrollView.frame))
        XCTAssertTrue(pauseCapture.exists)
        XCTAssertFalse(element(in: app, identifier: "copilot.audio.muteToggle").exists)
        XCTAssertFalse(element(in: app, identifier: "copilot.generation.stop").exists)
        for number in 1...3 {
            XCTAssertTrue(
                element(in: app, identifier: "copilot.followUp.question.\(number)")
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(
                element(in: app, identifier: "copilot.followUp.answer.\(number)")
                    .waitForExistence(timeout: 5)
            )
        }

        let originalAnswerFrame = answer.frame
        answer.click()

        let panel = element(in: app, identifier: "copilot.interviewLens.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "copilot.interviewLens.panel")
                .count,
            1
        )
        XCTAssertEqual(answer.frame.midX, originalAnswerFrame.midX, accuracy: 2)
        XCTAssertEqual(answer.frame.midY, originalAnswerFrame.midY, accuracy: 2)
        XCTAssertEqual(answer.frame.width, originalAnswerFrame.width, accuracy: 2)
        XCTAssertEqual(answer.frame.height, originalAnswerFrame.height, accuracy: 2)

        let fontScale = element(in: app, identifier: "copilot.interviewLens.fontScale")
        XCTAssertTrue(fontScale.waitForExistence(timeout: 2))
        let originalFontScale = fontScale.label
        element(in: app, identifier: "copilot.interviewLens.fontIncrease").click()
        XCTAssertTrue(waitForCondition(timeout: 2) { fontScale.label != originalFontScale })

        let originalPanelFrame = panel.frame
        let title = element(in: app, identifier: "copilot.interviewLens.title")
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        XCTAssertTrue(title.label.hasSuffix("参考回答"))

        followUps.click()
        XCTAssertTrue(waitForCondition(timeout: 2) { title.label.hasSuffix("可能追问") })
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "copilot.interviewLens.panel")
                .count,
            1
        )
        XCTAssertEqual(panel.frame.maxY, originalPanelFrame.maxY, accuracy: 4)

        // One live switch above covers the original synchronous resize crash.
        // Reopen alternating card types to stress repeated dynamic sizing
        // without asking XCUITest to click controls obscured by the lens panel.
        for index in 0..<6 {
            element(in: app, identifier: "copilot.interviewLens.close").click()
            XCTAssertFalse(panel.waitForExistence(timeout: 2))
            (index.isMultiple(of: 2) ? answer : followUps).click()
            XCTAssertTrue(panel.waitForExistence(timeout: 2))
        }
        XCTAssertTrue(panel.exists)

        let pageCounter = element(in: app, identifier: "copilot.interviewLens.pageCounter")
        XCTAssertTrue(pageCounter.waitForExistence(timeout: 2))
        let firstFollowUpPage = pageCounter.label
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(title.label.hasSuffix("可能追问"))
        XCTAssertTrue(waitForCondition(timeout: 2) { pageCounter.label != firstFollowUpPage })

        element(in: app, identifier: "copilot.interviewLens.close").click()
        XCTAssertFalse(panel.waitForExistence(timeout: 2))

        answer.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertNotEqual(
            element(in: app, identifier: "copilot.interviewLens.fontScale").label,
            originalFontScale
        )
        element(in: app, identifier: "copilot.interviewLens.close").click()
        XCTAssertFalse(panel.waitForExistence(timeout: 2))
        XCTAssertTrue(element(in: app, accessibilityLabel: "运行详情").exists)
    }

    func testSessionSmokeRoutesGenerateNotesIntoMainWindowDetail() {
        let app = launchApp(scenario: "sessionSmoke")

        let toggle = element(in: app, identifier: "app.controlBar.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        toggle.click()
        XCTAssertTrue(element(in: app, accessibilityLabel: "暂停收音").waitForExistence(timeout: 5))

        app.typeKey("l", modifierFlags: [.command, .shift])
        let generateNotes = element(in: app, identifier: "app.generateNotesButton")
        XCTAssertTrue(generateNotes.waitForExistence(timeout: 5))
        generateNotes.click()

        XCTAssertTrue(element(in: app, identifier: "home.detailPane").waitForExistence(timeout: 5))
    }

    func testNotesSmokeSupportsDeepLinkAndGeneration() async {
        let app = launchApp(scenario: "notesSmoke")

        let deepLink = URL(string: "liveinterviewcopilot://notes?sessionID=session_ui_test_notes")!
        await openDeepLink(deepLink)

        XCTAssertTrue(element(in: app, identifier: "notes.generateButton").waitForExistence(timeout: 5))
        element(in: app, identifier: "notes.generateButton").click()
        XCTAssertTrue(element(in: app, identifier: "notes.renderedMarkdown").waitForExistence(timeout: 5))
    }

    func testHomeTimelineSelectsSavedSessionAndCollapsesDetail() {
        let app = launchApp(scenario: "notesSmoke")
        app.activate()
        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 2))
        focus(window: mainWindow)

        let savedSession = element(in: app, identifier: "home.timeline.session.session_ui_test_notes")
        XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
        savedSession.click()

        XCTAssertTrue(element(in: app, identifier: "home.detailPane").waitForExistence(timeout: 5))

        let closeDetail = element(in: app, identifier: "home.detail.close")
        XCTAssertTrue(closeDetail.waitForExistence(timeout: 5))
        closeDetail.click()
        XCTAssertFalse(element(in: app, identifier: "home.detailPane").waitForExistence(timeout: 2))
    }

    func testHomeTimelineSupportsRenamingFromDetailManageMenu() {
        let app = launchApp(scenario: "notesSmoke")
        app.activate()
        let mainWindow = app.windows["main"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 2))
        focus(window: mainWindow)

        let savedSession = element(in: app, identifier: "home.timeline.session.session_ui_test_notes")
        XCTAssertTrue(savedSession.waitForExistence(timeout: 5))
        savedSession.click()

        XCTAssertTrue(element(in: app, identifier: "home.detailPane").waitForExistence(timeout: 5))

        let manageButton = element(in: app, identifier: "meetingDetail.manage")
        XCTAssertTrue(manageButton.waitForExistence(timeout: 5))
        manageButton.click()

        let renameMenuItem = app.menuItems["Rename..."]
        XCTAssertTrue(renameMenuItem.waitForExistence(timeout: 5))
        renameMenuItem.click()

        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.click()
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Renamed Discovery Call")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Renamed Discovery Call"].waitForExistence(timeout: 5))
    }

    func testNotesSmokeSupportsRenamingFromContextMenu() async {
        let app = launchApp(scenario: "notesSmoke")

        let deepLink = URL(string: "liveinterviewcopilot://notes?sessionID=session_ui_test_notes")!
        await openDeepLink(deepLink)

        let sessionRow = element(in: app, identifier: "notes.session.session_ui_test_notes")
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 5))

        sessionRow.rightClick()

        let renameMenuItem = app.menuItems["Rename..."]
        XCTAssertTrue(renameMenuItem.waitForExistence(timeout: 5))
        renameMenuItem.click()

        let renameField = app.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.click()
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Renamed Discovery Call")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        let titleLabel = app.staticTexts["Renamed Discovery Call"]
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 5))
    }

    private func launchApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LIVE_INTERVIEW_COPILOT_UI_TEST"] = "1"
        app.launchEnvironment["LIVE_INTERVIEW_COPILOT_UI_SCENARIO"] = scenario
        app.launchEnvironment["LIVE_INTERVIEW_COPILOT_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        return app
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(in app: XCUIApplication, accessibilityLabel: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", accessibilityLabel)
        ).firstMatch
    }

    private func elements(
        in app: XCUIApplication,
        identifierPrefix: String
    ) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        )
    }

    private func hasAudibleMeterValue(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.doubleValue > 0
        }
        guard let text = element.value as? String else { return false }
        if text == "检测到声音" { return true }
        let normalized = text
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (Double(normalized) ?? 0) > 0
    }

    private func focus(window: XCUIElement) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).click()
    }

    private func openDeepLink(_ url: URL) async {
        let hostAppURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LiveInterviewCopilotUITestHost.app", isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: hostAppURL.path))

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let openError = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: hostAppURL, configuration: configuration) { _, error in
                continuation.resume(returning: error)
            }
        }
        XCTAssertNil(openError)
    }

    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
