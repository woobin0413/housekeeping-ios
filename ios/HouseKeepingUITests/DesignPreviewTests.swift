import XCTest

@MainActor
final class DesignPreviewTests: XCTestCase {
    func testReviewEditSaveAndSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["addPurchase"].waitForExistence(timeout: 10))
        capture("Inventory")
        app.buttons["addPurchase"].tap()
        app.buttons["Try sample photo"].tap()
        XCTAssertTrue(app.buttons["savePurchase"].waitForExistence(timeout: 5))
        capture("Photo review")
        let name = app.textFields["itemName"].exists ? app.textFields["itemName"] : app.textViews["itemName"]
        name.tap()
        name.typeText("Tea ")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["savePurchase"].tap()
        XCTAssertTrue(app.staticTexts["saveConfirmation"].waitForExistence(timeout: 5))
        let search = app.textFields["inventorySearch"]
        search.tap()
        search.typeText("MATTE tea\n")
        XCTAssertEqual(app.staticTexts["itemCount"].label, "1 item")
        app.buttons.matching(identifier: "purchaseRow").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Purchase details"].waitForExistence(timeout: 5))
        capture("Purchase detail")
    }

    func testManualEntryValidationAndNoResults() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.buttons["addPurchase"].tap()
        app.buttons["Enter manually"].tap()
        XCTAssertTrue(app.buttons["savePurchase"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["savePurchase"].isEnabled)
        app.buttons["Cancel"].tap()
        let search = app.textFields["inventorySearch"]
        search.tap()
        search.typeText("a purchase that does not exist\n")
        XCTAssertEqual(app.staticTexts["itemCount"].label, "0 items")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No Results")).firstMatch.exists)
        capture("No results")
    }

    func testChangedDraftValidationAndDiscard() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.buttons["addPurchase"].tap()
        app.buttons["Enter manually"].tap()
        XCTAssertTrue(app.buttons["savePurchase"].waitForExistence(timeout: 5))
        let name = app.textFields["itemName"].exists ? app.textFields["itemName"] : app.textViews["itemName"]
        name.tap()
        name.typeText(String(repeating: "a", count: 201))
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        XCTAssertFalse(app.buttons["savePurchase"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Keep editing"].waitForExistence(timeout: 5))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(app.buttons["savePurchase"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["Discard changes"].tap()
        XCTAssertEqual(app.staticTexts["itemCount"].label, "3 items")
    }

    func testDarkAccessibleLayout() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--preview-dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["addPurchase"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["addPurchase"].isHittable)
        XCTAssertGreaterThan(
            app.staticTexts["inventoryHeading"].frame.height, 100,
            "Content must still use accessibility-size text outside the compact action")
        assertCompactAction(app.buttons["addPurchase"])
        capture("Inventory dark accessible")
        app.buttons["addPurchase"].tap()
        app.buttons["Try sample photo"].tap()
        XCTAssertTrue(app.buttons["savePurchase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["savePurchase"].isHittable)
        assertCompactAction(app.buttons["savePurchase"])
        capture("Photo review dark accessible")
    }

    func testDarkLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--preview-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["addPurchase"].waitForExistence(timeout: 10))
        capture("Inventory dark")
        app.buttons["addPurchase"].tap()
        app.buttons["Try sample photo"].tap()
        XCTAssertTrue(app.buttons["savePurchase"].waitForExistence(timeout: 5))
        capture("Photo review dark")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertCompactAction(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(button.frame.height, 56, "Preserve the primary tap target", file: file, line: line)
        XCTAssertLessThanOrEqual(
            button.frame.height, 72, "Pinned actions must not dominate the screen", file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44, file: file, line: line)
    }
}
