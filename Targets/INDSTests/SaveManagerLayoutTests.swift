import XCTest
@testable import eNDS

/// "Export Save for 3DS Card": the folder Checkpoint / JKSM restore to a game card
/// has the save files directly inside, with no wrapper folder and no metadata file.
final class SaveManagerLayoutTests: XCTestCase {
    func testFlatFolderHasFilesAtTopLevel() throws {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("SMLT-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src) }
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let main = src.appendingPathComponent("main"), sys = src.appendingPathComponent("sys")
        try Data([1, 2, 3]).write(to: main)
        try Data([4]).write(to: sys)

        let out = try ThreeDSSaveArchive.makeFlatFolder(containing: [main, sys], named: "Game: save/(3DS card)")
        defer { try? fm.removeItem(at: out.deletingLastPathComponent()) }

        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: out.path)), ["main", "sys"])
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent(ThreeDSSaveArchive.metadataName).path))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("main")), Data([1, 2, 3]))
        // A save manager's backup folder (or this one) stages as-is for import.
        let staged = try ThreeDSSaveArchive.stage(from: [out])
        defer { try? fm.removeItem(at: staged) }
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: staged.path)), ["main", "sys"])
    }

    func testRawSavImageIsRefused() throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("SMLT-\(UUID().uuidString).sav")
        try Data(repeating: 7, count: 131072).write(to: file)
        defer { try? fm.removeItem(at: file) }
        XCTAssertThrowsError(try ThreeDSSaveArchive.stage(from: [file])) {
            XCTAssertEqual(($0 as? SaveTransferError)?.errorDescription, SaveTransferError.rawCardSave.errorDescription)
        }
    }

    func testDeSmuMEFooterIsStripped() {
        let raw = Data(repeating: 9, count: 8192)
        let footer = Data(repeating: 0, count: 122 - 16) + Data("|-DESMUME SAVE-|".utf8)
        XCTAssertTrue(DSSaveImport.hasDeSmuMEFooter(raw + footer))
        XCTAssertEqual(DSSaveImport.stripDeSmuMEFooter(raw + footer), raw)
        XCTAssertFalse(DSSaveImport.hasDeSmuMEFooter(raw))
        XCTAssertEqual(DSSaveImport.stripDeSmuMEFooter(raw), raw)
    }

    func testImportSetsAsideAutoResumeState() throws {
        let fm = FileManager.default
        let name = "SMLT-\(UUID().uuidString)"
        let dir = try XCTUnwrap(fm.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("SaveStates/\(name)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("auto.mln"))
        DSSaveImport.setAsideAutoResumeState(baseName: name)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("auto.mln").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("auto.before-import.mln").path))
    }

    /// Saves with sub-folders (TOA_000/<file>) keep them on export and on import.
    func testNestedFoldersSurviveExportAndImport() throws {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("SMLT-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src) }
        for dir in ["TOA_000", "TOA_001"] {
            try fm.createDirectory(at: src.appendingPathComponent(dir), withIntermediateDirectories: true)
            try Data([1, 2]).write(to: src.appendingPathComponent("\(dir)/slot"))
        }
        try Data([3]).write(to: src.appendingPathComponent("TOASYS"))
        let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)

        let out = try ThreeDSSaveArchive.makeFlatFolder(containing: items, named: "Nested")
        defer { try? fm.removeItem(at: out.deletingLastPathComponent()) }
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("TOA_000/slot").path))

        // Whole backup folder picked.
        let a = try ThreeDSSaveArchive.stage(from: [out])
        defer { try? fm.removeItem(at: a) }
        XCTAssertTrue(fm.fileExists(atPath: a.appendingPathComponent("TOA_001/slot").path))
        XCTAssertTrue(fm.fileExists(atPath: a.appendingPathComponent("TOASYS").path))

        // The sub-folders and the file picked together.
        let b = try ThreeDSSaveArchive.stage(from: items)
        defer { try? fm.removeItem(at: b) }
        XCTAssertTrue(fm.fileExists(atPath: b.appendingPathComponent("TOA_000/slot").path))
        XCTAssertTrue(fm.fileExists(atPath: b.appendingPathComponent("TOA_001/slot").path))
    }
}
