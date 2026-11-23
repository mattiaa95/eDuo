import XCTest

/// What a user does with a game delivered as a .zip (Safari download, Files, eDuo import).
/// Needs `python3 -m http.server 8099` serving JamClown-for-eDuo-review.zip on the Mac
/// (the simulator shares the host's localhost). Screens land in /tmp/zip-flow-ui.
final class ReviewerFlowUITests: XCTestCase {
    let out = "/tmp/zip-flow-ui"
    let zipName = "JamClown-for-eDuo-review.zip"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    }

    private func shoot(_ n: String) {
        FileManager.default.createFile(atPath: "\(out)/\(n).png", contents: XCUIScreen.main.screenshot().pngRepresentation)
    }
    private func dump(_ app: XCUIApplication, _ n: String) {
        try? app.debugDescription.write(toFile: "\(out)/\(n).txt", atomically: true, encoding: .utf8)
    }

    /// Flow 3: Safari downloads the .zip, it lands in Files > Downloads.
    func test1SafariDownloadsZip() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        sleep(2)
        let url = safari.textFields["TabBarItemTitle"].firstMatch
        let bar = safari.buttons["URL"].firstMatch
        if bar.waitForExistence(timeout: 5) { bar.tap() } else if url.waitForExistence(timeout: 3) { url.tap() }
        sleep(1)
        safari.typeText("http://localhost:8099/\(zipName)\n")
        sleep(3)
        shoot("s1-safari-prompt"); dump(safari, "s1")
        let dl = safari.buttons["Download"].firstMatch
        XCTAssertTrue(dl.waitForExistence(timeout: 8), "no Download prompt")
        dl.tap()
        sleep(3)
        shoot("s2-safari-downloaded")
    }

    /// Flows 1 (Files side): tap the zip in Files > Downloads.
    func test2FilesTapZip() throws {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        sleep(3)
        shoot("f1-files"); dump(files, "f1")
        let browse = files.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        sleep(1)
        let dlCell = files.cells.containing(NSPredicate(format: "label CONTAINS 'Downloads'")).firstMatch
        if dlCell.waitForExistence(timeout: 5) { dlCell.tap() } else { files.staticTexts["Downloads"].firstMatch.tap() }
        sleep(3)
        shoot("f2-downloads"); dump(files, "f2")
        let z = files.staticTexts[zipName.replacingOccurrences(of: ".zip", with: "")].firstMatch
        let z2 = files.staticTexts[zipName].firstMatch
        let item = z2.exists ? z2 : z
        XCTAssertTrue(item.waitForExistence(timeout: 5), "zip not listed")
        // Tap the file icon, not the name label (a tap on the label starts a rename).
        let cell = files.cells.containing(NSPredicate(format: "label CONTAINS 'JamClown'")).firstMatch
        if cell.exists { cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() } else { item.tap() }
        sleep(3)
        shoot("f3-after-tap"); dump(files, "f3")
    }

    /// Flow 2: eDuo "+" > Import from Files > the .zip.
    func test3EDuoImportZipFromFiles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-eNDSHasSeenWelcome", "YES"]
        app.launch()
        sleep(2)
        shoot("e1-library"); dump(app, "e1")
        let plus = app.buttons["Import ROM"].firstMatch
        if plus.waitForExistence(timeout: 3) { plus.tap() } else { app.buttons["Import ROMs"].firstMatch.tap() }
        sleep(1)
        let imp = app.buttons["Import from Files"].firstMatch
        if imp.waitForExistence(timeout: 2) { imp.tap() }
        sleep(3)
        shoot("e2-picker"); dump(app, "e2")
        let br = app.buttons["Browse"].firstMatch
        if br.waitForExistence(timeout: 3) { br.tap() }
        sleep(1)
        let dl = app.staticTexts["Downloads"].firstMatch
        if dl.waitForExistence(timeout: 4) { dl.tap() }
        sleep(2)
        shoot("e3-downloads"); dump(app, "e3")
        let z = app.staticTexts[zipName].firstMatch
        let z0 = app.staticTexts[zipName.replacingOccurrences(of: ".zip", with: "")].firstMatch
        let item = z.exists ? z : z0
        XCTAssertTrue(item.waitForExistence(timeout: 5), "zip not selectable in picker")
        item.tap()
        sleep(1)
        let open = app.buttons["Open"].firstMatch
        if open.exists { open.tap() }
        sleep(4)
        shoot("e4-after-import"); dump(app, "e4")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'clown'")).firstMatch.waitForExistence(timeout: 5), "game not in library")
    }
}
