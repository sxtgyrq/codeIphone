import XCTest

/// Touch workflows use the Debug-only, version-checking in-process fixture.
/// No test connects to or edits the user's real ArgumentMap Server.
final class MapEditingUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["MAP_UI_SCENARIO"] = "editing"
        app.launch()
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText("http://192.168.0.100:61011")
        app.textFields["userName"].tap(); app.textFields["userName"].typeText("demo")
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("test-password\n")
        let notNow = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not Now", "暂不"])).firstMatch
        if notNow.waitForExistence(timeout: 6), notNow.isHittable { notNow.tap() }
        XCTAssertTrue(app.staticTexts["mapCounts"].waitForExistence(timeout: 15))
        // Map counts can exist behind the system Password AutoFill sheet. Wait
        // for an actual touch target and dismiss only the recognized prompt.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if notNow.exists && notNow.isHittable { notNow.tap() }
            return app.buttons["tool-line"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        expectCounts(app, lines: 2, nodes: 6, crosses: 1)
        XCTAssertTrue(app.staticTexts["releaseVersion"].exists)
        return app
    }

    private func expectCounts(_ app: XCUIApplication, lines: Int, nodes: Int, crosses: Int, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "线路 \(lines) · LN \(nodes) · Cross \(crosses)"), object: app.staticTexts["mapCounts"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, file: file, line: line)
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 8), identifier, file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, identifier, file: file, line: line)
        if !button.isHittable {
            for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(button.isHittable, identifier, file: file, line: line)
        button.tap()
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
    }

    private func coordinate(_ app: XCUIApplication, _ x: String, _ y: String) {
        tap(app, "coordinatesButton")
        let xField = app.textFields["cursorX"].exists ? app.textFields["cursorX"] : app.textFields["X"]
        let yField = app.textFields["cursorY"].exists ? app.textFields["cursorY"] : app.textFields["Y"]
        replace(xField, with: x)
        replace(yField, with: y)
        tap(app, "applyCoordinates")
        XCTAssertTrue(app.buttons["coordinatesButton"].waitForExistence(timeout: 5))
    }

    private func choose(_ app: XCUIApplication, tool: String, object: String) {
        tap(app, "tool-" + tool)
        tap(app, "objectList")
        tap(app, object)
        XCTAssertTrue(app.buttons["selectedEdit"].waitForExistence(timeout: 5))
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLineCreateEditPropertiesCopyAndUndoWithTouchControls() {
        let app = launch()
        tap(app, "tool-line"); tap(app, "newLine")
        coordinate(app, "400", "300"); tap(app, "addPoint")
        coordinate(app, "420", "300"); tap(app, "addPoint")
        tap(app, "saveDraft")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        // First generated fixture code. Re-open the saved version before editing.
        choose(app, tool: "line", object: "line-ZZZZZZZZAB")
        tap(app, "selectedEdit")
        coordinate(app, "420", "320"); tap(app, "addPoint")
        tap(app, "saveDraft")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        tap(app, "selectedMore"); tap(app, "lineProperties")
        replace(app.textFields["lineName"], with: "触摸测试")
        replace(app.textFields["lineSpeed"], with: "120")
        app.switches["lineTwoWay"].tap()
        tap(app, "saveLineProperties")
        XCTAssertTrue(app.staticTexts["线路 · 触摸测试"].waitForExistence(timeout: 8))
        screenshot(app, "手机线路编辑与属性保存")
        tap(app, "selectedMore"); tap(app, "复制线路")
        tap(app, "moreTools"); tap(app, "粘贴")
        coordinate(app, "500", "300")
        tap(app, "placementConfirm")
        expectCounts(app, lines: 4, nodes: 6, crosses: 1)
        tap(app, "undoMap"); tap(app, "确认撤销")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        choose(app, tool: "line", object: "line-ZZZZZZZZAB")
        tap(app, "selectedMore"); tap(app, "lineProperties")
        XCTAssertEqual(app.textFields["lineName"].value as? String, "触摸测试")
        XCTAssertEqual(app.textFields["lineSpeed"].value as? String, "120")
    }

    func testCrossAllFiveStatesCanBeSelectedWithoutKeyboardShortcuts() {
        let app = launch()
        let crossID = "cross-BBBBBBBBBB-AAAAAAAAAA"
        for state in [2, 3, -1, 0, 1] {
            choose(app, tool: "cross", object: crossID)
            tap(app, "selectedEdit")
            tap(app, "crossState\(state)")
            if state == 2 { screenshot(app, "Cross直接选择单向换路") }
            tap(app, "saveCrossState")
            XCTAssertTrue(app.buttons["selectedEdit"].waitForExistence(timeout: 8))
            choose(app, tool: "cross", object: crossID)
            tap(app, "selectedDetails")
            let expected: String
            switch state {
            case -1: expected = "不连通"
            case 0: expected = "未设置"
            case 1: expected = "双向换路"
            case 2: expected = "Road1 → Road2"
            default: expected = "Road2 → Road1"
            }
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
            tap(app, "完成")
        }
    }

    func testLogicalNodeNotCreationEditingAndMapMove() {
        let app = launch()
        tap(app, "tool-node"); tap(app, "newNode"); tap(app, "nodeSize-8")
        coordinate(app, "600.5", "300.5"); tap(app, "placementConfirm")
        tap(app, "logicalNodeRelation")
        tap(app, "¬ · 非（NOT）")
        XCTAssertTrue(app.staticTexts["logicalNodeGeneratedLogic"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["logicalNodeGeneratedLogic"].label, "¬(?)")
        screenshot(app, "手机新增LN8非节点")
        tap(app, "saveLogicalNode")
        expectCounts(app, lines: 2, nodes: 7, crosses: 1)
        choose(app, tool: "node", object: "node-ZZZZZZZZAB")
        tap(app, "selectedEdit")
        tap(app, "logicalNodeRelation"); tap(app, "↔ · 等价")
        tap(app, "saveLogicalNode")
        XCTAssertTrue(app.staticTexts["LN8 · ↔"].waitForExistence(timeout: 8))
        tap(app, "selectedMore"); tap(app, "移动节点")
        coordinate(app, "620.5", "320.5"); tap(app, "placementConfirm")
        expectCounts(app, lines: 2, nodes: 7, crosses: 1)
        choose(app, tool: "node", object: "node-ZZZZZZZZAB")
        tap(app, "selectedDetails")
        XCTAssertTrue(app.staticTexts["620.5, 320.5"].waitForExistence(timeout: 5))
    }

    func testAreaMovePreviewCanBeCancelledWithoutWriting() {
        let app = launch()
        tap(app, "tool-area"); tap(app, "beginArea")
        coordinate(app, "70", "80"); tap(app, "placementConfirm")
        coordinate(app, "240", "140"); tap(app, "placementConfirm")
        let counts = app.staticTexts["areaCounts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 8))
        XCTAssertEqual(counts.label, "选中 1 条线路 · 5 个 LN · 0 个 Cross")
        tap(app, "areaMove")
        coordinate(app, "400", "300")
        screenshot(app, "手机框选整组移动预览")
        tap(app, "cancelDraft")
        expectCounts(app, lines: 2, nodes: 6, crosses: 1)
        choose(app, tool: "node", object: "node-EEEEEEEEEE")
        tap(app, "selectedDetails")
        XCTAssertTrue(app.staticTexts["150.5, 110.5"].waitForExistence(timeout: 5))
    }
}
