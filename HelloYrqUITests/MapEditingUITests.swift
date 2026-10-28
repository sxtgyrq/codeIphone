import XCTest

/// Touch workflows use the Debug-only, version-checking in-process fixture.
/// No test connects to or edits the user's real ArgumentMap Server.
final class MapEditingUITests: XCTestCase {
    private func launch(captureScreens: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["MAP_UI_SCENARIO"] = "editing"
        app.launch()
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        if captureScreens { screenshot(app, "手机登录页") }
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
        if captureScreens { screenshot(app, "手机地图主页与发布日期") }
        return app
    }

    private func expectCounts(_ app: XCUIApplication, lines: Int, nodes: Int, crosses: Int, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "线路 \(lines) · LN \(nodes) · Cross \(crosses)"), object: app.staticTexts["mapCounts"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, file: file, line: line)
    }

    private func tap(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier]
        reveal(app, button)
        XCTAssertTrue(button.exists, identifier, file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, identifier, file: file, line: line)
        XCTAssertTrue(button.isHittable, identifier, file: file, line: line)
        button.tap()
    }

    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        // A saved sheet can still be animating away while the underlying view
        // already exists. Let the transition finish before scrolling a form.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        if XCTWaiter.wait(for: [visible], timeout: 3) == .completed { return }
        for _ in 0..<6 where !element.exists || !element.isHittable { scrollForm(app) }
    }

    private func scrollForm(_ app: XCUIApplication) {
        // Scroll inside the form's viewport, which shrinks above the keyboard.
        // A whole-screen swipe can otherwise begin on the software keyboard.
        if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
        else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
        else { app.swipeUp() }
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Callers use the form's explicit Clear control first. Empty UIKit
        // text fields can expose their placeholder as the accessibility value.
        let old = field.value as? String ?? ""
        XCTAssertTrue(old.isEmpty || old == field.placeholderValue, "Clear the field before entering its replacement")
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value, "The field must contain only the replacement text")
    }

    private func coordinate(_ app: XCUIApplication, _ x: String, _ y: String) {
        tap(app, "coordinatesButton")
        let xField = app.textFields["cursorX"].exists ? app.textFields["cursorX"] : app.textFields["X"]
        let yField = app.textFields["cursorY"].exists ? app.textFields["cursorY"] : app.textFields["Y"]
        tap(app, "clear-cursorX")
        replace(xField, with: x)
        tap(app, "clear-cursorY")
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
        let app = launch(captureScreens: true)
        tap(app, "tool-line"); tap(app, "newLine")
        coordinate(app, "400", "300"); tap(app, "addPoint")
        coordinate(app, "420", "300"); tap(app, "addPoint")
        screenshot(app, "手机线路草稿与准星")
        tap(app, "saveDraft")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        // First generated fixture code. Re-open the saved version before editing.
        choose(app, tool: "line", object: "line-ZZZZZZZZAB")
        tap(app, "selectedEdit")
        coordinate(app, "420", "320"); tap(app, "addPoint")
        tap(app, "saveDraft")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        tap(app, "selectedMore"); tap(app, "lineProperties")
        tap(app, "clear-lineName")
        replace(app.textFields["lineName"], with: "触摸测试")
        tap(app, "clear-lineSpeed")
        replace(app.textFields["lineSpeed"], with: "120")
        reveal(app, app.switches["lineTwoWay"])
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

    func testLogicalNodeConnectionPreviewSaveAndUndo() {
        let app = launch()
        choose(app, tool: "node", object: "node-DDDDDDDDDD")
        tap(app, "selectedMore"); tap(app, "连接另一个 LN")
        tap(app, "从列表选择"); tap(app, "node-EEEEEEEEEE")
        XCTAssertTrue(app.buttons["previewConnection"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["saveConnection"].isEnabled)
        tap(app, "previewConnection")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["saveConnection"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        screenshot(app, "手机LN连接预览")
        tap(app, "saveConnection")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        tap(app, "undoMap"); tap(app, "确认撤销")
        expectCounts(app, lines: 2, nodes: 6, crosses: 1)
    }

    func testLineSplitThenMergeUsesPreviewAndCanBeUndone() {
        let app = launch()
        tap(app, "tool-line"); tap(app, "newLine")
        for (x, y) in [("400", "300"), ("420", "300"), ("420", "320"), ("440", "320")] {
            coordinate(app, x, y); tap(app, "addPoint")
        }
        tap(app, "saveDraft")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        choose(app, tool: "line", object: "line-ZZZZZZZZAB")
        tap(app, "selectedMore"); tap(app, "拆分线路")
        XCTAssertTrue(app.buttons["saveSplit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveSplit"].isEnabled)
        tap(app, "节点 3 前 · (420, 320)")
        screenshot(app, "手机线路拆分预览")
        tap(app, "saveSplit")
        expectCounts(app, lines: 4, nodes: 6, crosses: 1)
        choose(app, tool: "line", object: "line-ZZZZZZZZAB")
        tap(app, "selectedMore"); tap(app, "合并线路")
        tap(app, "从列表选择"); tap(app, "line-ZZZZZZZZAC")
        XCTAssertTrue(app.buttons["previewMerge"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["saveMerge"].isEnabled)
        tap(app, "previewMerge")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["saveMerge"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        screenshot(app, "手机线路合并预览")
        tap(app, "saveMerge")
        expectCounts(app, lines: 3, nodes: 6, crosses: 1)
        tap(app, "undoMap"); tap(app, "确认撤销")
        expectCounts(app, lines: 4, nodes: 6, crosses: 1)
    }

    func testFlowJSONRequiresPreviewBeforeImportAndCanBeUndone() {
        let app = launch()
        tap(app, "moreTools"); tap(app, "导入流程图")
        let json = #"{"format":"argumentmap.flow/1","origin":"p","ln":[{"id":"p","at":[100.5,100.5],"size":6,"value":"Imported","logic":"UI_FLOW_PROP"}],"roads":[{"id":"r","points":[[90,100],[110,100]],"name":"Flow"}],"crosses":[]}"#
        let editor = app.textViews["flowJSON"]
        tap(app, "clear-flowJSON")
        reveal(app, editor)
        XCTAssertTrue(editor.exists)
        replace(editor, with: json)
        XCTAssertFalse(app.buttons["saveFlow"].isEnabled)
        let x = app.textFields["flowOriginX"], y = app.textFields["flowOriginY"]
        tap(app, "clear-flowOriginX"); replace(x, with: "700.5")
        tap(app, "clear-flowOriginY"); replace(y, with: "500.5")
        tap(app, "previewFlow")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["saveFlow"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        scrollForm(app)
        screenshot(app, "手机流程图导入预览")
        tap(app, "saveFlow")
        expectCounts(app, lines: 3, nodes: 7, crosses: 1)
        tap(app, "undoMap"); tap(app, "确认撤销")
        expectCounts(app, lines: 2, nodes: 6, crosses: 1)
    }

    func testAreaCopyPasteAndUndoPreservesTheOriginalGroup() {
        let app = launch()
        tap(app, "tool-area"); tap(app, "beginArea")
        coordinate(app, "70", "80"); tap(app, "placementConfirm")
        coordinate(app, "240", "140"); tap(app, "placementConfirm")
        XCTAssertTrue(app.staticTexts["areaCounts"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["areaCounts"].label, "选中 1 条线路 · 5 个 LN · 0 个 Cross")
        tap(app, "areaCopy")
        // The native PasteButton reads the JSON copied by the app, exercising
        // the same clipboard route used for WPF/iOS exchange.
        tap(app, "moreTools"); tap(app, "pasteSystemClipboard")
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.navigationBars["地图工具"])
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 10), .completed,
                       "The system paste callback must close its panel before choosing the new position")
        coordinate(app, "400", "300")
        screenshot(app, "手机整组复制落点预览")
        tap(app, "placementConfirm")
        expectCounts(app, lines: 3, nodes: 11, crosses: 1)
        tap(app, "undoMap"); tap(app, "确认撤销")
        expectCounts(app, lines: 2, nodes: 6, crosses: 1)
        choose(app, tool: "node", object: "node-EEEEEEEEEE")
        tap(app, "selectedDetails")
        XCTAssertTrue(app.staticTexts["150.5, 110.5"].waitForExistence(timeout: 5))
    }
}
