import XCTest

final class HelloYrqUITests: XCTestCase {
    func testLaunchShowsGreeting() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let greeting = app.staticTexts["greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15))
        XCTAssertEqual(greeting.label, "你好，要瑞卿")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "你好，要瑞卿"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
