import XCTest

/// Screenshot harness v2 — final App Store captures (post feature merge).
/// The app launches with -eNDSScreenshotHarness: no system dialogs, the touch
/// overlay forced on even when a "controller" is present (the simulator's
/// keyboard), and no Connected toast.
final class ScreenshotTests: XCTestCase {

    let outDir = "/tmp/inds-screenshots"

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private var deviceSuffix: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    @discardableResult
    private func launchApp(welcomeSeen: Bool = true, extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-eNDSScreenshotHarness", "YES",
                               "-eNDSHasSeenWelcome", welcomeSeen ? "YES" : "NO"] + extraArgs
        app.launch()
        return app
    }

    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(outDir)/\(name)-\(deviceSuffix).png", contents: png)
    }

    private func bootJamClown(_ app: XCUIApplication) {
        let pred = NSPredicate(format: "label CONTAINS[c] %@", "clown")
        let cell = app.staticTexts.matching(pred).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 8), "JamClown cell not found")
        cell.tap()
        sleep(14)
    }

    private func openSaveStateSheet(_ app: XCUIApplication) {
        for label in ["Save State", "Save States", "Save & Load"] {
            let row = app.buttons[label].firstMatch
            if row.waitForExistence(timeout: 2) { row.tap(); return }
            let txt = app.staticTexts[label].firstMatch
            if txt.waitForExistence(timeout: 1) { txt.tap(); return }
        }
    }

    private func openPauseMenu(_ app: XCUIApplication) {
        let pause = app.buttons["hud.pause"]
        if pause.waitForExistence(timeout: 4) {
            pause.tap()
        } else {
            // fallback: the HUD's top-left corner
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.055)).tap()
        }
        sleep(2)
    }

    @MainActor
    func test01_Library() throws {
        _ = launchApp()
        sleep(4)
        shoot("library")
    }

    @MainActor
    func test02_Welcome() throws {
        let app = launchApp(welcomeSeen: false)
        sleep(4)
        shoot("welcome-1")
        app.swipeLeft(); sleep(1)
        app.swipeLeft(); sleep(1)
        shoot("welcome-3")
    }

    @MainActor
    func test03_HeroPortrait() throws {
        let app = launchApp()
        sleep(2)
        bootJamClown(app)
        shoot("hero-portrait")
    }

    @MainActor
    func test04_HeroLandscape() throws {
        let app = launchApp()
        sleep(2)
        bootJamClown(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        shoot("hero-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    @MainActor
    func test05_PauseAndSaves() throws {
        let app = launchApp()
        sleep(2)
        bootJamClown(app)
        openPauseMenu(app)
        shoot("pause-menu")

        // Really saves into slot 1 and comes back in, so the sheet shows a
        // real thumbnail instead of four "Empty" rows. It doubles as the check
        // that capture → write → read → draw works end to end.
        openSaveStateSheet(app)
        let slot1 = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Slot 1")).firstMatch
        if slot1.waitForExistence(timeout: 4) { slot1.tap() }
        sleep(3)

        // After saving, sometimes the pause menu stays open and sometimes the
        // game comes back. If the menu is still there, reopening it covers the
        // shot.
        if !app.buttons["Save State"].firstMatch.waitForExistence(timeout: 2) {
            openPauseMenu(app)
        }
        openSaveStateSheet(app)
        // sheet-over-sheet is slow: at 2 s the capture lands half-presented
        sleep(5)
        shoot("save-states")
    }

    @MainActor
    func test06_Cheats() throws {
        let app = launchApp()
        sleep(2)
        bootJamClown(app)
        openPauseMenu(app)
        for label in ["Cheats", "Cheat Codes"] {
            let row = app.buttons[label].firstMatch
            if row.waitForExistence(timeout: 2) { row.tap(); break }
            let txt = app.staticTexts[label].firstMatch
            if txt.waitForExistence(timeout: 1) { txt.tap(); break }
        }
        sleep(5)
        shoot("cheats")
    }

    @MainActor
    func test07_LayoutEditor() throws {
        let app = launchApp()
        sleep(2)
        tapAny(app, labels: ["Settings", "gearshape"])
        sleep(1)
        tapAny(app, labels: ["Controls"])
        sleep(1)
        for label in ["Edit Layout", "Layout Editor", "Customize Layout", "Edit On-Screen Controls"] {
            let el = app.buttons[label].firstMatch
            if el.waitForExistence(timeout: 2) { el.tap(); break }
            let txt = app.staticTexts[label].firstMatch
            if txt.waitForExistence(timeout: 1) { txt.tap(); break }
        }
        sleep(2)
        let ids = ["dpad", "a", "b", "x", "y", "l", "r", "start", "select", "menu", "layout", "fastForward"]
        func verifyEditor() {
            let controls = ids.map { app.buttons["layout-editor-\($0)"].firstMatch }
            for control in controls {
                XCTAssertTrue(control.exists)
                XCTAssertTrue(control.isHittable)
            }
            let frames = controls.map(\.frame)
            for i in controls.indices {
                for j in controls.indices where j > i {
                    let overlap = frames[i].intersection(frames[j])
                    XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                                  "Editor controls overlap: \(ids[i]), \(ids[j])")
                }
            }
        }
        verifyEditor()
        shoot("layout-editor")
        app.segmentedControls.buttons["Landscape"].tap()
        verifyEditor()
        shoot("layout-editor-landscape")
        let a = app.buttons["layout-editor-a"].firstMatch
        let before = a.frame.midX
        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -35, dy: -30)))
        XCTAssertLessThan(a.frame.midX, before - 20, "Dragging must use the scaled canvas coordinates")
    }

    @MainActor
    func test08_Settings() throws {
        let app = launchApp()
        sleep(2)
        tapAny(app, labels: ["Settings", "gearshape"])
        sleep(2)
        shoot("settings")
    }

    @MainActor
    func test09_Paywall() throws {
        let app = launchApp()
        sleep(2)
        tapAny(app, labels: ["Settings", "gearshape"])
        sleep(1)
        tapAny(app, labels: ["eDuo PRO"])
        sleep(3)
        shoot("paywall")
    }

    /// The App Review screenshot of the three in-app purchases: all plans
    /// revealed and scrolled so the prices, the button and the renewal terms
    /// share one frame. Retake it whenever the paywall changes — the old one
    /// sat in App Store Connect for weeks describing a paywall that no longer
    /// existed.
    @MainActor
    func test16_PaywallReview() throws {
        let app = launchApp()
        sleep(2)
        tapAny(app, labels: ["Settings", "gearshape"])
        sleep(1)
        tapAny(app, labels: ["eDuo PRO"])
        sleep(4)
        tapAny(app, labels: ["See all plans"])
        sleep(2)
        let start = app.scrollViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(2)
        shoot("paywall-review")
    }

    @MainActor
    func test10_About() throws {
        let app = launchApp()
        sleep(2)
        tapAny(app, labels: ["Settings", "gearshape"])
        sleep(1)
        tapAny(app, labels: ["About"])
        sleep(1)
        app.swipeUp()
        sleep(1)
        shoot("about-bottom")
    }

    /// Long-press preview card over the library (ROMDetailView). Plays first
    /// so the card has the things that make it worth showing: a real gameplay
    /// thumbnail and a save state.
    @MainActor
    func test11_ROMPreview() throws {
        let warmup = launchApp()
        sleep(2)
        bootJamClown(warmup)
        warmup.terminate()
        sleep(2)

        let app = launchApp()
        sleep(4)
        let pred = NSPredicate(format: "label CONTAINS[c] %@", "clown")
        let matches = app.staticTexts.matching(pred)
        // The same title also appears in the "Continue Playing" row at the top,
        // which has no context menu — take the lowest match, i.e. the grid cell.
        var target: XCUIElement?
        for i in 0..<matches.count {
            let el = matches.element(boundBy: i)
            guard el.exists else { continue }
            if target == nil || el.frame.minY > target!.frame.minY { target = el }
        }
        let cell = try XCTUnwrap(target, "JamClown grid cell not found")
        cell.press(forDuration: 1.4)
        sleep(3)
        shoot("rom-preview")
    }

    /// Settings › Controls. Not bound for the store listing: it is the page
    /// that moves the most (turbo, haptics, opacity, mapping) and one capture
    /// reviews all of it.
    @MainActor
    func test12_Controls() throws {
        let app = launchApp()
        sleep(2)
        tapAny(app, labels: ["Settings", "gearshape"])
        sleep(1)
        tapAny(app, labels: ["Controls"])
        sleep(2)
        app.swipeUp()
        sleep(1)
        shoot("controls")
    }

    /// Reel for the App Preview: no shots, it only drives the app at a human pace
    /// while `simctl io recordVideo` films it. The edit picks the seconds later.
    @MainActor
    func test20_Reel() throws {
        let app = launchApp()
        sleep(3)
        bootJamClown(app)
        // play: tap the three targets on the touch screen
        for i in 0..<12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: [0.18, 0.5, 0.82][i % 3], dy: 0.44)).tap()
            usleep(600_000)
        }
        // fast forward from the HUD, a few seconds, then back to normal
        let ff = app.buttons["hud.fastForward"]
        if ff.waitForExistence(timeout: 2) { ff.tap() }
        sleep(5)
        if ff.exists { ff.tap() }
        sleep(1)
        openPauseMenu(app)
        tapAny(app, labels: ["Cheats"])
        sleep(3)
        let toggle = app.switches.element(boundBy: max(0, app.switches.count - 1))
        if toggle.exists { toggle.tap() }
        sleep(3)
        app.swipeDown()
        sleep(2)
        openSaveStateSheet(app)
        sleep(2)
        let slot1 = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Slot 1")).firstMatch
        if slot1.waitForExistence(timeout: 4) { slot1.tap() }
        let overwrite = app.buttons["Overwrite"].firstMatch
        if overwrite.waitForExistence(timeout: 2) { overwrite.tap() }
        sleep(3)
        if !app.buttons["Save State"].firstMatch.waitForExistence(timeout: 2) { openPauseMenu(app) }
        openSaveStateSheet(app)
        sleep(5)
        app.terminate()
        let again = launchApp()
        sleep(3)
        tapAny(again, labels: ["Settings", "gearshape"])
        sleep(1)
        tapAny(again, labels: ["Controls"])
        sleep(1)
        tapAny(again, labels: ["Customize Layout"])
        sleep(3)
        let a = again.buttons["layout-editor-a"].firstMatch
        if a.waitForExistence(timeout: 3) {
            let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: -60, dy: -80)), withVelocity: .slow, thenHoldForDuration: 0.6)
        }
        sleep(4)
    }

    private func tapAny(_ app: XCUIApplication, labels: [String]) {
        for label in labels {
            let b = app.buttons[label].firstMatch
            if b.waitForExistence(timeout: 3) { b.tap(); return }
            let t = app.staticTexts[label].firstMatch
            if t.waitForExistence(timeout: 1) { t.tap(); return }
        }
    }

    @MainActor
    func test15_AutomaticScreenPreference() throws {
        continueAfterFailure = false
        let app = launchApp()
        tapAny(app, labels: ["Settings"])
        tapAny(app, labels: ["Screens"])
        let landscape = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Landscape")).firstMatch
        XCTAssertTrue(landscape.waitForExistence(timeout: 5))
        XCTAssertTrue(landscape.label.contains("Automatic"), landscape.label)
        landscape.tap()
        app.buttons["Side by Side"].tap()
        XCTAssertTrue(landscape.label.contains("Side by Side"), landscape.label)
        app.terminate()
        app.launch()
        tapAny(app, labels: ["Settings"])
        tapAny(app, labels: ["Screens"])
        XCTAssertTrue(landscape.label.contains("Side by Side"), landscape.label)
        landscape.tap()
        app.buttons["Automatic"].tap()
        XCTAssertTrue(landscape.label.contains("Automatic"), landscape.label)
    }

    /// Expanded default: controls flank the lower display through rotation,
    /// then a real save/load round trip leaves the same game playable.
    @MainActor
    func test14_ExpandedDSGameplay() throws {
        continueAfterFailure = false
        let app = launchApp(extraArgs: ["-eNDSStretchScreens", "NO", "-eNDSScreenSwap", "NO"])
        bootJamClown(app)
        let top = app.images["DS top screen"]
        let touch = app.descendants(matching: .any)["DS touch screen"].firstMatch
        XCTAssertTrue(top.waitForExistence(timeout: 10))
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let settled = NSPredicate { _, _ in
                top.exists && touch.exists && top.frame.maxY < touch.frame.minY
                    && abs(top.frame.midX - touch.frame.midX) < 2
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10), .completed)
            for screen in [top, touch] {
                XCTAssertEqual(screen.frame.width / screen.frame.height, 4.0 / 3.0, accuracy: 0.02)
                XCTAssertTrue(app.frame.contains(screen.frame))
            }
            for name in ["Directional pad", "A button", "B button", "X button", "Y button",
                         "L shoulder button", "R shoulder button", "Start button", "Select button", "hud.pause"] {
                let button = app.buttons[name]
                XCTAssertTrue(button.isHittable, name)
                XCTAssertFalse(button.frame.intersects(top.frame), name)
                XCTAssertFalse(button.frame.intersects(touch.frame), name)
            }
            XCTAssertLessThan(app.buttons["Directional pad"].frame.maxX, touch.frame.minX)
            XCTAssertGreaterThan(app.buttons["A button"].frame.minX, touch.frame.maxX)
            touch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1))
                .press(forDuration: 0.1, thenDragTo: touch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)))
            app.buttons["Start button"].tap()
            app.buttons["A button"].tap()
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "ds-console-\(orientation.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.buttons["hud.pause"].tap()
        XCTAssertTrue(app.buttons["Save State"].waitForExistence(timeout: 5))
        app.buttons["Save State"].tap()
        let slot = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Slot 1")).firstMatch
        XCTAssertTrue(slot.waitForExistence(timeout: 5))
        slot.tap()
        if app.buttons["Overwrite"].waitForExistence(timeout: 1) { app.buttons["Overwrite"].tap() }
        if !app.buttons["Load State"].waitForExistence(timeout: 3) { app.buttons["hud.pause"].tap() }
        app.buttons["Load State"].tap()
        XCTAssertTrue(slot.waitForExistence(timeout: 5))
        XCTAssertTrue(slot.isEnabled)
        XCTAssertFalse(slot.label.contains("Empty"))
        slot.tap()
        if app.buttons["Resume"].waitForExistence(timeout: 3) { app.buttons["Resume"].tap() }
        XCTAssertTrue(app.buttons["hud.pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(touch.isHittable)
    }

    /// Requires JamClown.nds in Documents/ROMs of the test simulator.
    /// One running game crosses both shapes and returns;
    /// screenshots are attached to xcresult as reproducible evidence.
    @MainActor
    func test13_AdaptiveGameplay() throws {
        continueAfterFailure = false
        let app = launchApp(extraArgs: ["-eNDSScreenLayoutPortrait", "stacked",
                                        "-eNDSScreenLayoutLandscape", "sideBySide",
                                        "-eNDSStretchScreens", "NO",
                                        "-eNDSScreenSwap", "NO"])
        bootJamClown(app)
        let top = app.images["DS top screen"]
        let touch = app.descendants(matching: .any)["DS touch screen"].firstMatch
        XCTAssertTrue(top.waitForExistence(timeout: 10))
        XCTAssertTrue(touch.exists)
        defer { XCUIDevice.shared.orientation = .portrait }

        for (orientation, name) in [(UIDeviceOrientation.portrait, "adaptive-portrait"),
                                    (.landscapeLeft, "adaptive-landscape"),
                                    (.portrait, "adaptive-return-portrait")] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let settled = NSPredicate { _, _ in
                guard top.exists, touch.exists else { return false }
                return landscape
                    ? abs(top.frame.midY - touch.frame.midY) < 2 && top.frame.maxX <= touch.frame.minX + 1
                    : abs(top.frame.midX - touch.frame.midX) < 2 && top.frame.maxY <= touch.frame.minY + 1
            }
            let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
            for screen in [top, touch] {
                XCTAssertGreaterThan(screen.frame.height, 50)
                XCTAssertEqual(screen.frame.width / screen.frame.height, 4.0 / 3.0, accuracy: 0.02)
                XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(screen.frame))
            }
            XCTAssertTrue(app.buttons["hud.pause"].isHittable)
            touch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Open the live menu after the return trip: catches a stranded HUD
        // or a session replaced by the library during the transition.
        app.buttons["hud.pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
    }

    /// Requires JamClown.nds in Documents/ROMs. Rewind shows up once the
    /// first capture exists (3.5 s of play) and jumps back without leaving
    /// the game stuck paused; three jumps in a row must all land.
    @MainActor
    func test17_Rewind() throws {
        continueAfterFailure = false
        let app = launchApp(extraArgs: [])
        bootJamClown(app)
        XCTAssertTrue(app.buttons["hud.pause"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 15)
        for _ in 0..<3 {
            app.buttons["hud.pause"].tap()
            XCTAssertTrue(app.buttons["Rewind"].waitForExistence(timeout: 5))
            app.buttons["Rewind"].tap()
            XCTAssertTrue(app.buttons["hud.pause"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Resume"].exists)
            Thread.sleep(forTimeInterval: 1)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "after-rewind"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
