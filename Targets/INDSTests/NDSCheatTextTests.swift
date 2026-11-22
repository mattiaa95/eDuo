import XCTest
@testable import eNDS

final class NDSCheatTextTests: XCTestCase {
    func testRoundTripEnabledAndDisabled() {
        let cheats = [
            NDSCheat(name: "Infinite HP", code: "023FE000 00000063\n123FE004 00000001", enabled: true),
            NDSCheat(name: "Money", code: "023FE008 000003E7", enabled: false)
        ]
        let back = GatewayCheatText.parse(GatewayCheatText.serialize(cheats))
        XCTAssertEqual(back.map(\.name), ["Infinite HP", "Money"])
        XCTAssertEqual(back.map(\.enabled), [true, false])
        XCTAssertEqual(back.map(\.code), cheats.map(\.code))
        XCTAssertEqual(GatewayCheatText.serialize(back), GatewayCheatText.serialize(cheats))
    }

    func testFormatIsTheThreeDSOne() {
        let text = GatewayCheatText.serialize([NDSCheat(name: "A", code: "023fe000 00000063", enabled: true)])
        XCTAssertEqual(text, "[A]\n*citra_enabled\n023FE000 00000063\n")
    }

    func testCommentsInvalidLinesAndCRLF() {
        let text = "* a comment\r\n[One]\r\n*citra_enabled\r\n# note\r\nnot a code\r\n023FE000 00000063\r\n023FE0 0000000063\r\n; x\r\n// y\r\n[Two]\r\n"
        let cheats = GatewayCheatText.parse(text)
        XCTAssertEqual(cheats.count, 2)
        XCTAssertEqual(cheats[0].code, "023FE000 00000063")
        XCTAssertTrue(cheats[0].enabled)
        XCTAssertFalse(cheats[1].enabled)
        // A name with no code is not a cheat when written back.
        XCTAssertEqual(GatewayCheatText.serialize(cheats), "[One]\n*citra_enabled\n023FE000 00000063\n")
    }

    func testGarbageNeverCrashes() {
        XCTAssertTrue(GatewayCheatText.parse("").isEmpty)
        XCTAssertTrue(GatewayCheatText.parse("023FE000 00000063\n[").isEmpty)
        XCTAssertTrue(GatewayCheatText.parse("\u{0}\u{1}[]]\n").count <= 1)
    }

    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testMigratesMchWithoutLosingAnything() throws {
        let dir = tmp()
        let mch = dir.appendingPathComponent("g.mch"), txt = dir.appendingPathComponent("sub/g.txt")
        let old = NDSCheatFileStore.serialize([
            NDSCheat(name: "On", code: "023FE000 00000063", enabled: true),
            NDSCheat(name: "Off", code: "023FE008 000003E7", enabled: false)
        ])
        try old.write(to: mch, atomically: true, encoding: .utf8)
        let cheats = NDSCheatTextStore.sync(txt: txt, mch: mch)
        XCTAssertEqual(cheats.map(\.name), ["On", "Off"])
        XCTAssertEqual(GatewayCheatText.parse(try String(contentsOf: txt)).map(\.enabled), [true, false])
        XCTAssertEqual(try String(contentsOf: mch), old)
    }

    func testTextWinsOverMchAndEditsFromFilesAreRespected() throws {
        let dir = tmp()
        let mch = dir.appendingPathComponent("g.mch"), txt = dir.appendingPathComponent("g.txt")
        try NDSCheatFileStore.serialize([NDSCheat(name: "Old", code: "023FE000 00000063", enabled: true)])
            .write(to: mch, atomically: true, encoding: .utf8)
        NDSCheatTextStore.sync(txt: txt, mch: mch)
        try "[Edited]\n*citra_enabled\n023FE010 00000001\n".write(to: txt, atomically: true, encoding: .utf8)
        let cheats = NDSCheatTextStore.sync(txt: txt, mch: mch)
        XCTAssertEqual(cheats.map(\.name), ["Edited"])
        XCTAssertEqual(NDSCheatFileStore.parse(try String(contentsOf: mch)).map(\.name), ["Edited"])
    }

    func testDroppedTextWithoutMchAndDeletedText() throws {
        let dir = tmp()
        let mch = dir.appendingPathComponent("g.mch"), txt = dir.appendingPathComponent("g.txt")
        try "[Dropped]\n*citra_enabled\n023FE010 00000001\n".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(NDSCheatTextStore.sync(txt: txt, mch: mch).count, 1)
        XCTAssertTrue(NDSCheatFileStore.parse(try String(contentsOf: mch)).first?.enabled == true)
        try FileManager.default.removeItem(at: txt)
        XCTAssertTrue(NDSCheatTextStore.sync(txt: txt, mch: mch, mayMigrate: false).isEmpty)
        XCTAssertTrue(NDSCheatFileStore.parse(try String(contentsOf: mch)).isEmpty)
        XCTAssertTrue(NDSCheatTextStore.sync(txt: dir.appendingPathComponent("none.txt"), mch: nil).isEmpty)
    }

    func testCodeBreakerKeptAsTypedInTextTranslatedInMch() throws {
        let dir = tmp()
        let mch = dir.appendingPathComponent("g.mch"), txt = dir.appendingPathComponent("g.txt")
        try "[CB]\n*citra_enabled\n023FE000 00000063\n".write(to: txt, atomically: true, encoding: .utf8)
        NDSCheatTextStore.sync(txt: txt, mch: mch)
        XCTAssertEqual(try String(contentsOf: txt), "[CB]\n*citra_enabled\n023FE000 00000063\n")
    }

    func testGameCodeFromRomHeaderAndCheatsFolder() throws {
        let dir = tmp()
        var header = Data(count: 0x20)
        header.replaceSubrange(0x0C..<0x10, with: Data("BXWE".utf8))
        let rom = dir.appendingPathComponent("x.nds")
        try header.write(to: rom)
        XCTAssertEqual(NDSCheatTextStore.gameCode(at: rom), "BXWE")
        var bad = header; bad.replaceSubrange(0x0C..<0x10, with: Data([0, 1, 2, 3]))
        try bad.write(to: rom)
        XCTAssertNil(NDSCheatTextStore.gameCode(at: rom))
        XCTAssertNil(NDSCheatTextStore.gameCode(at: dir.appendingPathComponent("missing.nds")))
        // 3DS files are 16 hex digits, DS ones 4 characters: they never share a name.
        XCTAssertEqual(NDSCheatTextStore.fileURL(gameID: "BXWE", documents: dir).path,
                       dir.path + "/System/cheats/BXWE.txt")
    }
}
