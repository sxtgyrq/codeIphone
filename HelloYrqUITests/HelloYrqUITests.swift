import XCTest

final class HelloYrqUITests: XCTestCase {
    private func launch(_ scenario: String = "success") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["MAP_UI_SCENARIO"] = scenario
        app.launch()
        return app
    }

    private func login(_ app: XCUIApplication) {
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText("http://192.168.0.100:61011")
        let user = app.textFields["userName"]
        user.tap(); user.typeText("demo")
        let password = app.secureTextFields["password"]
        password.tap(); password.typeText("test-password\n")
        // iOS Password AutoFill presents this system sheet inside the app after
        // a successful login. Dismiss it as a user would before testing the map.
        let notNow = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not Now", "暂不"])).firstMatch
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLaunchRequiresServerAndCredentials() {
        let app = launch()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["loginButton"].isEnabled)
        XCTAssertFalse(app.otherElements["logicMap"].exists)
        screenshot(app, "登录页面")
    }

    func testLoginDisplaysMapAndSupportsBrowseControls() {
        let app = launch()
        login(app)
        let counts = app.staticTexts["mapCounts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 15))
        XCTAssertEqual(counts.label, "线路 2 · LN 6 · Cross 1")
        screenshot(app, "逻辑地图")
        app.buttons["fitMap"].tap()
        let canvas = app.descendants(matching: .any)["logicMap"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let coordinates = app.staticTexts["mapCoordinates"]
        XCTAssertTrue(coordinates.exists)
        let oldCoordinates = coordinates.label
        canvas.pinch(withScale: 2, velocity: 1)
        canvas.swipeLeft()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", oldCoordinates), object: coordinates)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        app.buttons["refreshMap"].tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "线路 2 · LN 7 · Cross 1"), object: counts)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        app.buttons["nodesButton"].tap()
        XCTAssertTrue(app.navigationBars["逻辑节点 · 7"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["¬(?)"].exists)
        screenshot(app, "逻辑节点列表")
        app.staticTexts["¬(?)"].tap()
        XCTAssertTrue(app.navigationBars["对象详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["¬(?)"].exists)
        screenshot(app, "NOT 节点详情")
    }

    func testInvalidPasswordStaysOnLogin() {
        let app = launch("invalid-login")
        login(app)
        XCTAssertTrue(app.staticTexts["loginError"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["loginError"].label.contains("密码"))
        XCTAssertFalse(app.staticTexts["mapCounts"].exists)
    }

    func testConnectionFailureKeepsLoginForm() {
        let app = launch("unreachable")
        login(app)
        XCTAssertTrue(app.staticTexts["loginError"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["userName"].value as? String, "demo")
        XCTAssertTrue(app.buttons["loginButton"].isEnabled)
    }

    func testExpiredSessionClearsMapAndReturnsToLogin() {
        let app = launch("expired")
        login(app)
        XCTAssertTrue(app.staticTexts["mapCounts"].waitForExistence(timeout: 15))
        app.buttons["refreshMap"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["loginError"].label.contains("失效"))
        XCTAssertFalse(app.staticTexts["mapCounts"].exists)
        XCTAssertTrue(app.secureTextFields["password"].value as? String == "账号密码" || app.secureTextFields["password"].value as? String == "")
    }

    func testRefreshFailureRetainsCompletePreviousMap() {
        let app = launch("refresh-failure")
        login(app)
        XCTAssertTrue(app.staticTexts["mapCounts"].waitForExistence(timeout: 15))
        app.buttons["refreshMap"].tap()
        XCTAssertTrue(app.staticTexts["mapError"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["mapCounts"].label, "线路 2 · LN 6 · Cross 1")
    }

    func testEmptyMapIsNotReportedAsConnectionFailure() {
        let app = launch("empty")
        login(app)
        XCTAssertTrue(app.staticTexts["地图暂时为空"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["mapCounts"].label, "线路 0 · LN 0 · Cross 0")
    }

    func testLogoutReturnsToLoginAndDoesNotRememberPassword() {
        let app = launch()
        login(app)
        XCTAssertTrue(app.staticTexts["mapCounts"].waitForExistence(timeout: 15))
        app.buttons["accountMenu"].tap()
        app.buttons["logoutButton"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["loginButton"].isEnabled)
        XCTAssertFalse(app.staticTexts["mapCounts"].exists)
    }
}
