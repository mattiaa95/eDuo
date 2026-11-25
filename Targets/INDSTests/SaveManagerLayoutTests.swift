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
}
