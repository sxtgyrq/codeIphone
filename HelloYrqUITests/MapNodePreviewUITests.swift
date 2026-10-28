import XCTest

/// This scenario is served only by the in-process editing fixture.
final class MapNodePreviewUITests: XCTestCase {
    func testReadOnlyRelatedNodePreviewPreservesUnsavedBranchDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["MAP_UI_SCENARIO"] = "editing"
        installPasswordSavePromptMonitor()
        app.launch()
        let address = app.textFields["serverAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText("http://192.168.0.100:61011")
        app.textFields["userName"].tap(); app.textFields["userName"].typeText("demo")
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("test-password\n")
        waitForReadyControl(app.buttons["tool-node"], in: app, timeout: 20)
        tap(app.buttons["tool-node"], in: app)
        tap(app.buttons["objectList"], in: app)
        tap(app.buttons["node-CCCCCCCCCC"], in: app)
        tap(app.buttons["selectedEdit"], in: app)

        let falseBranch = app.segmentedControls["logicalNodeBranch"].buttons["False · 否"]
        tap(falseBranch, in: app)
        let logic = app.textFields["logicalNodeLogic"]
        reveal(logic, in: app)
        XCTAssertEqual(logic.value as? String, "¬示例命题")
        let info = app.textViews["logicalNodeInfo"]
        reveal(info, in: app)
        info.tap(); info.typeText(" Preview draft retained")
        let draftInfo = info.value as? String
        XCTAssertTrue(draftInfo?.contains("Preview draft retained") == true)
        tap(app.buttons["收起键盘"], in: app)

        tap(app.buttons["previewNode-EEEEEEEEEE"], in: app)
        let coordinates = app.staticTexts["previewNodeCoordinates"]
        XCTAssertTrue(coordinates.waitForExistence(timeout: 8))
        XCTAssertEqual(coordinates.label, "X 150.5 · Y 110.5")
        let map = app.descendants(matching: .any)["logicMap"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertEqual(map.label, "逻辑地图，2 条线路，6 个逻辑节点")
        tap(app.buttons["previewFitMap"], in: app)
        tap(app.buttons["previewLocateNode"], in: app)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "保留未保存草稿的关联 LN 只读预览"
        attachment.lifetime = .keepAlways
        add(attachment)
        tap(app.buttons["returnToNodeEditor"], in: app)

        reveal(info, in: app, towardTop: true)
        XCTAssertEqual(info.value as? String, draftInfo)
        reveal(logic, in: app, towardTop: true)
        XCTAssertEqual(logic.value as? String, "¬示例命题")
        reveal(falseBranch, in: app, towardTop: true)
        XCTAssertTrue(falseBranch.isSelected)
        // No Save is tapped anywhere. Cancel/reopen must expose the unchanged
        // fixture, proving that preview navigation did not persist the draft.
        tap(app.navigationBars["编辑 LN4"].buttons["取消"], in: app)
        tap(app.buttons["selectedEdit"], in: app)
        let trueBranch = app.segmentedControls["logicalNodeBranch"].buttons["True · 是"]
        reveal(trueBranch, in: app)
        XCTAssertTrue(trueBranch.isSelected)
        reveal(logic, in: app)
        XCTAssertEqual(logic.value as? String, "示例命题")
        reveal(info, in: app)
        XCTAssertEqual(info.value as? String, "仅用于原生 UI 测试")
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        tapReadyControl(element, in: app)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        dismissKnownPasswordSavePrompt(in: app)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if self.dismissKnownPasswordSavePrompt(in: app) { return false }
            return element.exists && element.isHittable
        }, object: nil)
        if XCTWaiter.wait(for: [visible], timeout: 3) == .completed { return }
        for _ in 0..<6 where !element.exists || !element.isHittable {
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            XCTAssertTrue(scroll.exists)
            if towardTop { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        waitForReadyControl(element, in: app)
    }
}
