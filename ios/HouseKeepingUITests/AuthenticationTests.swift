import XCTest

@MainActor
final class AuthenticationTests: XCTestCase {
    func testMissingConfigurationOffersExplicitDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--unconfigured"]
        app.launch()
        XCTAssertTrue(app.staticTexts["configurationStatus"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["addPurchase"].exists)
        app.buttons["exploreDemo"].tap()
        XCTAssertTrue(app.buttons["addPurchase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OFFLINE DEMO"].exists)
        app.buttons["Exit demo"].tap()
        XCTAssertTrue(app.staticTexts["configurationStatus"].waitForExistence(timeout: 5))
    }

    func testFailedSignInRetryThenSignOut() {
        let app = launchAuth()
        app.textFields["signInEmail"].tap()
        app.textFields["signInEmail"].typeText("person@example.invalid\n")
        app.secureTextFields["signInPassword"].typeText("wrong\n")
        XCTAssertTrue(app.staticTexts["signInError"].waitForExistence(timeout: 5))
        app.secureTextFields["signInPassword"].tap()
        app.secureTextFields["signInPassword"].typeText("demo-password\n")
        XCTAssertTrue(app.staticTexts["householdName"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addPurchase"].exists)
        XCTAssertEqual(app.staticTexts["accountEmail"].label, "person@example.invalid")
        capture("Connected account")
        app.buttons["signOut"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["accountEmail"].exists)
    }

    func testNoHouseholdDoesNotShowInventory() {
        let app = launchAuth()
        app.textFields["signInEmail"].tap()
        app.textFields["signInEmail"].typeText("unassigned@example.invalid\n")
        app.secureTextFields["signInPassword"].typeText("demo-password\n")
        XCTAssertTrue(app.staticTexts["noHousehold"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addPurchase"].exists)
        app.buttons["signOut"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    func testRecoveryRequestIsNeutralAndCancelable() {
        let app = launchAuth()
        app.buttons["beginRecovery"].tap()
        app.textFields["recoveryEmail"].tap()
        app.textFields["recoveryEmail"].typeText("person@example.invalid\n")
        XCTAssertTrue(app.staticTexts["recoveryEmailSent"].waitForExistence(timeout: 5))
        capture("Recovery email requested")
        app.buttons["closeRecovery"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    func testRecoveredPasswordMustMatchAndReturnsToSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-recovery"]
        app.launch()
        XCTAssertTrue(app.secureTextFields["newPassword"].waitForExistence(timeout: 10))
        app.secureTextFields["newPassword"].tap()
        app.secureTextFields["newPassword"].typeText("new-demo-password\n")
        app.secureTextFields["confirmPassword"].typeText("different-password\n")
        XCTAssertTrue(app.staticTexts["recoveryError"].waitForExistence(timeout: 5))
        app.secureTextFields["newPassword"].tap()
        app.secureTextFields["newPassword"].typeText("new-demo-password\n")
        app.secureTextFields["confirmPassword"].typeText("new-demo-password\n")
        XCTAssertTrue(app.staticTexts["passwordChanged"].waitForExistence(timeout: 5))
        app.buttons["closeRecovery"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    private func launchAuth() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-auth"]
        app.launch()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 10))
        capture("Sign in")
        return app
    }

    func testConnectedInventorySearchDetailsAndSignOut() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-inventory"]
        app.launch()
        XCTAssertTrue(app.textFields["signInEmail"].waitForExistence(timeout: 10))
        app.textFields["signInEmail"].tap()
        app.textFields["signInEmail"].typeText("person@example.invalid\n")
        app.secureTextFields["signInPassword"].typeText("demo-password\n")
        XCTAssertTrue(app.staticTexts["connectedInventoryHeading"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addPurchase"].exists)
        XCTAssertTrue(app.staticTexts["inventoryDevelopmentStatus"].exists)
        capture("Connected inventory fixture")
        app.buttons["connectedPurchaseRow"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["connectedDetailName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["connectedDetailName"].label, "Shared kettle")
        capture("Connected purchase details fixture")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let search = app.textFields["inventorySearch"]
        search.tap()
        search.typeText("no-matching-item\n")
        XCTAssertTrue(app.staticTexts["No matching purchases"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.buttons["connectedPurchaseRow"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["inventoryAccount"].tap()
        XCTAssertTrue(app.staticTexts["accountEmail"].waitForExistence(timeout: 5))
        app.buttons["signOut"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["connectedInventoryHeading"].exists)
    }

    func testConnectedInventoryAccessibleAccountAndSearchRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--preview-inventory", "--preview-dark", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.textFields["signInEmail"].waitForExistence(timeout: 10))
        app.textFields["signInEmail"].tap()
        app.textFields["signInEmail"].typeText("person@example.invalid\n")
        app.secureTextFields["signInPassword"].typeText("demo-password\n")
        let account = app.buttons["inventoryAccount"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable)
        // Accessibility geometry can report 43.99999999999997 for an exact 44-point target.
        XCTAssertGreaterThanOrEqual(account.frame.height + 0.0001, 44)
        let search = app.textFields["inventorySearch"]
        for _ in 0..<4 where !search.isHittable { app.swipeUp() }
        XCTAssertTrue(search.isHittable)
        capture("Connected inventory dark accessible fixture")
        account.tap()
        let signOut = app.buttons["signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        for _ in 0..<6 where !signOut.isHittable { app.swipeUp() }
        XCTAssertTrue(signOut.isHittable)
        signOut.tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    func testAccessibleSignInKeepsActionCompactAndReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--preview-auth", "--preview-dark", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let action = app.buttons["signInButton"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        for _ in 0..<4 where !action.isHittable { app.swipeUp() }
        XCTAssertTrue(action.isHittable)
        XCTAssertGreaterThanOrEqual(action.frame.height, 56)
        XCTAssertLessThanOrEqual(action.frame.height, 72)
        capture("Sign in dark accessible")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
