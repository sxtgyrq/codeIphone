import XCTest

/// Password AutoFill can appear after the first map frame. Recognize only this
/// system prompt; permission requests and application confirmations stay visible.
private enum MapPasswordSavePrompt {
    static let titles = ["Save Password?", "保存密码？", "保存密码?", "存储密码？", "存储密码?",
                         "储存密码？", "储存密码?", "儲存密碼？", "儲存密碼?"]
    static let declineLabels = ["Not Now", "暂不", "暫不"]

    static func dismiss(_ prompt: XCUIElement) -> Bool {
        guard prompt.exists else { return false }
        let title = prompt.staticTexts.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        guard titles.contains(prompt.label) || title.exists else { return false }
        let decline = prompt.buttons.matching(NSPredicate(format: "label IN %@", declineLabels)).firstMatch
        guard decline.exists, decline.isEnabled, decline.isHittable else { return false }
        decline.tap()
        return true
    }
}

extension XCTestCase {
    func installPasswordSavePromptMonitor() {
        // The monitor covers the race where the prompt appears after a ready
        // check but before the actual tap/gesture. XCTest retries that action.
        // https://developer.apple.com/documentation/xctest/handling-ui-interruptions
        addUIInterruptionMonitor(withDescription: "Decline only the system Save Password prompt") { prompt in
            MapPasswordSavePrompt.dismiss(prompt)
        }
    }

    @discardableResult
    func dismissKnownPasswordSavePrompt(in app: XCUIApplication) -> Bool {
        for prompt in app.sheets.allElementsBoundByIndex + app.alerts.allElementsBoundByIndex {
            if MapPasswordSavePrompt.dismiss(prompt) { return true }
        }
        return false
    }

    /// An existing status label is not proof that the map is ready: it can be
    /// mounted during login or remain visible behind a late AutoFill prompt.
    func waitForLoginOutcome(in app: XCUIApplication, timeout: TimeInterval = 20,
                             file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if self.dismissKnownPasswordSavePrompt(in: app) { return false }
            if app.staticTexts["loginError"].exists { return true }
            let refresh = app.buttons["refreshMap"]
            return app.staticTexts["mapCounts"].exists && refresh.exists && refresh.isEnabled && refresh.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "Login must show an error or a usable map", file: file, line: line)
    }

    @discardableResult
    func waitForReadyControl(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 15,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        func isReady() -> Bool {
            if dismissKnownPasswordSavePrompt(in: app) { return false }
            return element.exists && element.isEnabled && element.isHittable
        }
        if isReady() { return true }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in isReady() }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: timeout)
        XCTAssertEqual(result, .completed, "Control must exist, be enabled and be hittable",
                       file: file, line: line)
        return result == .completed
    }

    func tapReadyControl(_ element: XCUIElement, in app: XCUIApplication,
                         file: StaticString = #filePath, line: UInt = #line) {
        // Assert the combined readiness result instead of issuing separate AX
        // reads that can straddle an asynchronously appearing system prompt.
        let ready = waitForReadyControl(element, in: app, file: file, line: line)
        XCTAssertTrue(ready, "Cannot tap an absent, disabled or obscured control", file: file, line: line)
        guard ready else { return }
        element.tap()
    }
}
