import XCTest

@MainActor
final class SharedInventoryTests: XCTestCase {
    func testOfflineSampleSuggestionIsEditableBeforeSave() {
        let app = launchInventory(cameraArgument: "--preview-camera-authorized")
        signIn(app, email: "recognition-sample@example.invalid")
        capturePreviewPhoto(in: app)

        let request = app.buttons["requestRecognition"]
        makeHittable(request, in: app)
        request.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recognitionSuggestionReady"].waitForExistence(timeout: 5))
        let name = editorField(app, identifier: "connectedItemName")
        makeHittable(name, in: app)
        XCTAssertEqual(name.value as? String, "Sample recognized kettle")
        name.tap()
        name.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        name.typeText("Reviewed sample kettle")
        dismissKeyboard(app)
        app.buttons["connectedSavePurchase"].tap()
        XCTAssertTrue(app.staticTexts["Reviewed sample kettle"].waitForExistence(timeout: 5))
    }

    func testRecognitionTimeoutKeepsManualPhotoSaveAvailable() {
        let app = launchInventory(
            cameraArgument: "--preview-camera-authorized",
            extraArguments: ["--preview-recognition-timeout"])
        signIn(app, email: "recognition-timeout@example.invalid")
        capturePreviewPhoto(in: app)

        let request = app.buttons["requestRecognition"]
        makeHittable(request, in: app)
        request.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recognitionError"].waitForExistence(timeout: 5))
        let name = editorField(app, identifier: "connectedItemName")
        makeHittable(name, in: app)
        name.tap()
        name.typeText("Manual timeout fallback")
        dismissKeyboard(app)
        app.buttons["connectedSavePurchase"].tap()
        XCTAssertTrue(app.staticTexts["Manual timeout fallback"].waitForExistence(timeout: 5))
    }

    func testCameraCaptureRetakeAndDraftRecovery() {
        let app = launchInventory(cameraArgument: "--preview-camera-authorized")
        signIn(app, email: "camera@example.invalid")
        app.buttons["addPurchase"].tap()
        let camera = app.buttons["takePurchasePhoto"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        let capture = app.buttons["capturePurchasePhoto"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        XCTAssertTrue(app.descendants(matching: .any)["capturedPhotoPreview"].waitForExistence(timeout: 5))
        app.buttons["retakePurchasePhoto"].tap()
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        let usePhoto = app.buttons["useCapturedPhoto"]
        XCTAssertTrue(usePhoto.waitForExistence(timeout: 5))
        usePhoto.tap()
        XCTAssertTrue(app.buttons["Discard photo"].waitForExistence(timeout: 10))
        app.buttons["keepPurchaseDraft"].tap()
        let resume = app.buttons["continueInventoryDraft"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.buttons["Discard photo"].waitForExistence(timeout: 5))
    }

    func testDeniedCameraFallsBackToLibraryAndManualEntry() {
        let app = launchInventory(cameraArgument: "--preview-camera-denied")
        signIn(app, email: "camera-denied@example.invalid")
        app.buttons["addPurchase"].tap()
        app.buttons["takePurchasePhoto"].tap()
        XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 5))
        app.buttons["cameraFallback"].tap()
        XCTAssertTrue(app.buttons["choosePurchasePhoto"].waitForExistence(timeout: 5))
        let name = editorField(app, identifier: "connectedItemName")
        makeHittable(name, in: app)
        name.tap()
        name.typeText("Manual camera fallback")
        dismissKeyboard(app)
        app.buttons["connectedSavePurchase"].tap()
        XCTAssertTrue(app.staticTexts["Manual camera fallback"].waitForExistence(timeout: 5))
    }

    func testImportedPhotoSavesAndDisplaysForOtherSpouse() throws {
        guard ProcessInfo.processInfo.environment["HK_PHOTO_UI_FIXTURE"] == "1" else {
            throw XCTSkip("Seed the synthetic January 2, 2030 simulator photo before opting in")
        }
        let app = launchInventory()
        signIn(app, email: "photo-author@example.invalid")
        app.buttons["addPurchase"].tap()
        let picker = app.buttons["choosePurchasePhoto"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        makeHittable(picker, in: app)
        picker.tap()
        let fixture = app.images.matching(
            NSPredicate(format: "label MATCHES %@", ".*January 0?2, 2030.*")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), "The seeded synthetic photo must be identifiable by date")
        guard fixture.exists else { return }
        // The system picker exposes a visible grid image but no accessibility hit point on iOS 26.5.
        // Use that date-identified element's center, never a guessed cell or another library image.
        guard app.frame.contains(fixture.frame), !fixture.frame.isEmpty else {
            XCTFail("Synthetic photo must be fully visible")
            return
        }
        fixture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Discard photo"].waitForExistence(timeout: 10))
        let name = editorField(app, identifier: "connectedItemName")
        // The photo makes the form taller; place the field above the persistent bottom action.
        for _ in 0..<6 where name.frame.midY > app.frame.height * 0.65 { app.swipeUp() }
        makeHittable(name, in: app)
        name.tap()
        name.typeText("Shared photo fixture")
        dismissKeyboard(app)
        app.buttons["connectedSavePurchase"].tap()
        XCTAssertTrue(app.staticTexts["Shared photo fixture"].waitForExistence(timeout: 10))
        let thumbnail = app.descendants(matching: .any)["purchaseThumbnail"].firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        signOut(app)
        signIn(app, email: "photo-reader@example.invalid")
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        let listScreenshot = XCTAttachment(screenshot: app.screenshot())
        listScreenshot.name = "Other spouse's genuine list thumbnail"
        listScreenshot.lifetime = .keepAlways
        add(listScreenshot)
        app.staticTexts["Shared photo fixture"].tap()
        let image = app.descendants(matching: .any)["sharedPurchasePhoto"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        returnToInventory(app)
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        app.staticTexts["Shared photo fixture"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Other spouse's genuine imported photo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let remove = app.buttons["removePurchasePhoto"]
        makeHittable(remove, in: app)
        remove.tap()
        app.alerts.buttons["Keep photo"].tap()
        XCTAssertTrue(image.exists)
        remove.tap()
        app.alerts.buttons["confirmRemovePurchasePhoto"].firstMatch.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        XCTAssertFalse(image.exists)
        XCTAssertEqual(app.staticTexts["connectedDetailName"].label, "Shared photo fixture")
        returnToInventory(app)
        XCTAssertFalse(thumbnail.exists)
        app.staticTexts["Shared photo fixture"].tap()
        XCTAssertTrue(app.staticTexts["connectedDetailName"].waitForExistence(timeout: 5))
        makeHittable(app.buttons["deletePurchase"], in: app)
        app.buttons["deletePurchase"].tap()
        app.alerts.buttons["Delete purchase"].tap()
        XCTAssertTrue(app.staticTexts["connectedInventoryHeading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Shared photo fixture"].exists)
    }

    func testPhotoPickerAndKeepDraftAreReachable() {
        let app = launchInventory()
        signIn(app, email: "photo@example.invalid")
        app.buttons["addPurchase"].tap()
        let picker = app.buttons["choosePurchasePhoto"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        makeHittable(picker, in: app)
        picker.tap()
        let photosNavigation = app.navigationBars["Photos"]
        let cancelPicker = photosNavigation.buttons["Cancel"]
        XCTAssertTrue(cancelPicker.waitForExistence(timeout: 5))
        cancelPicker.tap()
        XCTAssertTrue(photosNavigation.waitForNonExistence(timeout: 5))
        let keep = app.buttons["keepPurchaseDraft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertTrue(keep.isHittable)
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["continueInventoryDraft"].waitForExistence(timeout: 5))
        makeHittable(app.buttons["continueInventoryDraft"], in: app)
        app.buttons["continueInventoryDraft"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Photo draft editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTwoAccountsCreateEditAndDeleteSharedPurchase() {
        let app = launchInventory()
        signIn(app, email: "first@example.invalid")
        XCTAssertTrue(app.buttons["addPurchase"].waitForExistence(timeout: 5))
        app.buttons["addPurchase"].tap()
        XCTAssertTrue(app.buttons["connectedSavePurchase"].waitForExistence(timeout: 5))
        let name = editorField(app, identifier: "connectedItemName")
        name.tap()
        name.typeText("Shared toaster")
        dismissKeyboard(app)
        let quantity = app.steppers["itemQuantityStepper"]
        makeHittable(quantity, in: app)
        quantity.buttons["itemQuantityStepper-Increment"].tap()
        let restockLimit = app.steppers["itemRestockLimitStepper"]
        makeHittable(restockLimit, in: app)
        restockLimit.buttons["itemRestockLimitStepper-Increment"].tap()
        XCTAssertTrue(app.buttons["connectedSavePurchase"].isEnabled)
        app.buttons["connectedSavePurchase"].tap()
        XCTAssertTrue(app.staticTexts["Shared toaster"].waitForExistence(timeout: 5))

        signOut(app)
        signIn(app, email: "second@example.invalid")
        XCTAssertTrue(app.staticTexts["Shared toaster"].waitForExistence(timeout: 5))
        app.staticTexts["Shared toaster"].tap()
        XCTAssertTrue(app.staticTexts["connectedDetailName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["itemQuantity"].label.contains("On hand: 2"))
        XCTAssertTrue(app.descendants(matching: .any)["itemQuantity"].label.contains("Restock limit: 2"))
        XCTAssertTrue(app.descendants(matching: .any)["itemQuantity"].label.contains("Restock now"))
        makeHittable(app.buttons["editPurchase"], in: app)
        app.buttons["editPurchase"].tap()
        let editedName = editorField(app, identifier: "connectedItemName")
        editedName.tap()
        // Native paragraph selection avoids relying on the simulator's hardware-keyboard Command-A routing.
        editedName.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        editedName.typeText("Shared toaster updated")
        dismissKeyboard(app)
        makeHittable(quantity, in: app)
        quantity.buttons["itemQuantityStepper-Decrement"].tap()
        quantity.buttons["itemQuantityStepper-Decrement"].tap()
        app.buttons["connectedSavePurchase"].tap()
        let detailName = app.staticTexts["connectedDetailName"]
        XCTAssertTrue(detailName.waitForExistence(timeout: 5))
        XCTAssertEqual(detailName.label, "Shared toaster updated")
        let stock = app.descendants(matching: .any)["itemQuantity"]
        XCTAssertTrue(stock.label.contains("On hand: 0"))
        XCTAssertTrue(stock.label.contains("Out of stock"))
        XCTAssertTrue(stock.label.contains("Restock now"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shared purchase out of stock"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        makeHittable(app.buttons["deletePurchase"], in: app)
        app.buttons["deletePurchase"].tap()
        let confirmDelete = app.alerts.buttons["Delete purchase"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        XCTAssertTrue(app.staticTexts["connectedInventoryHeading"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Shared toaster updated"].exists)
    }

    func testDraftRestoresAfterForegroundAndRequiresExplicitDiscard() {
        let app = launchInventory()
        signIn(app, email: "person@example.invalid")
        app.buttons["addPurchase"].tap()
        let name = editorField(app, identifier: "connectedItemName")
        name.tap()
        name.typeText("Retained lamp")
        dismissKeyboard(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["continueInventoryDraft"].waitForExistence(timeout: 10))
        app.buttons["continueInventoryDraft"].tap()
        XCTAssertEqual(editorField(app, identifier: "connectedItemName").value as? String, "Retained lamp")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Keep editing"].waitForExistence(timeout: 5))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(app.buttons["connectedSavePurchase"].exists)
        app.buttons["Cancel"].tap()
        let confirmDiscard = app.alerts.buttons["confirmDiscardDraft"].firstMatch
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        confirmDiscard.tap()
        XCTAssertTrue(app.buttons["addPurchase"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["continueInventoryDraft"].exists)
    }

    private func returnToInventory(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["Back", "Your shared home"])
        ).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.staticTexts["connectedInventoryHeading"].waitForExistence(timeout: 5))
    }

    private func capturePreviewPhoto(in app: XCUIApplication) {
        app.buttons["addPurchase"].tap()
        app.buttons["takePurchasePhoto"].tap()
        let capture = app.buttons["capturePurchasePhoto"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        let usePhoto = app.buttons["useCapturedPhoto"]
        XCTAssertTrue(usePhoto.waitForExistence(timeout: 5))
        usePhoto.tap()
        XCTAssertTrue(app.buttons["Discard photo"].waitForExistence(timeout: 10))
    }

    private func launchInventory(
        cameraArgument: String? = nil, extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-inventory"] + extraArguments
        if let cameraArgument { app.launchArguments.append(cameraArgument) }
        app.launch()
        XCTAssertTrue(app.textFields["signInEmail"].waitForExistence(timeout: 10))
        return app
    }

    private func signIn(_ app: XCUIApplication, email: String) {
        let emailField = app.textFields["signInEmail"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        emailField.tap()
        emailField.typeText(email + "\n")
        app.secureTextFields["signInPassword"].typeText("demo-password\n")
        XCTAssertTrue(app.staticTexts["connectedInventoryHeading"].waitForExistence(timeout: 5))
    }

    private func signOut(_ app: XCUIApplication) {
        app.buttons["inventoryAccount"].tap()
        XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 5))
        makeHittable(app.buttons["signOut"], in: app)
        app.buttons["signOut"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    private func editorField(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let textField = app.textFields[identifier]
        return textField.exists ? textField : app.textViews[identifier]
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }

    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
