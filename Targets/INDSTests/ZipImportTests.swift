import XCTest
import zlib
@testable import eNDS

/// ROM-in-a-.zip import.
/// The archives are built here (stored entries + CRC32), so no fixtures.
final class ZipImportTests: XCTestCase {
    private var work: URL!
    private var created: [URL] = []

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("ZipImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
        for url in created { try? FileManager.default.removeItem(at: url) }
    }

    /// A 0x200-byte DS-looking header; `title` makes two ROMs differ.
    private func fakeROM(_ title: String) -> Data {
        var d = Data(count: 0x200)
        d.replaceSubrange(0..<min(12, title.utf8.count), with: Array(title.utf8.prefix(12)))
        d.replaceSubrange(0x0C..<0x10, with: Array("TEST".utf8))
        return d
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 255) } }

    private func makeZip(_ name: String, _ entries: [(String, Data)]) throws -> URL {
        var out = Data(), central = Data()
        for (n, data) in entries {
            let nameBytes = Array(n.utf8)
            let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let offset = UInt32(out.count)
            let common = le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0)
            out += le32(0x04034b50) + Data(common) + Data(nameBytes) + data
            central += Data(le32(0x02014b50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)) + Data(nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += Data(le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        let url = work.appendingPathComponent(name)
        try out.write(to: url)
        return url
    }

    private func imported(_ r: ROMImportResult) -> [String] {
        created += r.importedROMURLs
        return r.importedROMURLs.map(\.lastPathComponent).sorted()
    }

    func testRomAtRootIgnoresLicenseReadmeAndMacosx() throws {
        let zip = try makeZip("review.zip", [
            ("zipt-root.nds", fakeROM("Root")),
            ("LICENSE-MIT.txt", Data("mit".utf8)),
            ("README.txt", Data("hi".utf8)),
            ("__MACOSX/._zipt-root.nds", Data(repeating: 1, count: 100)),
        ])
        let r = try ROMStorageManager.importAny(from: zip, replaceExisting: false)
        XCTAssertEqual(imported(r), ["zipt-root.nds"])
        XCTAssertTrue(r.failureMessages.isEmpty)
    }

    func testRomInsideSubfolder() throws {
        let zip = try makeZip("sub.zip", [("Folder/Deep/zipt-sub.nds", fakeROM("Sub"))])
        XCTAssertEqual(imported(try ROMStorageManager.importAny(from: zip, replaceExisting: false)), ["zipt-sub.nds"])
    }

    func testSeveralRoms() throws {
        let zip = try makeZip("many.zip", [("zipt-a.nds", fakeROM("A")), ("x/zipt-b.NDS", fakeROM("B"))])
        XCTAssertEqual(imported(try ROMStorageManager.importAny(from: zip, replaceExisting: false)), ["zipt-a.nds", "zipt-b.nds"])
    }

    func testZipWithoutRomThrowsClearError() throws {
        let zip = try makeZip("none.zip", [("README.txt", Data("hi".utf8))])
        XCTAssertThrowsError(try ROMStorageManager.importAny(from: zip, replaceExisting: false)) { error in
            guard case ROMStorageError.zipContainsNoSupportedFiles = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testCorruptZipThrowsInsteadOfCrashing() throws {
        let url = work.appendingPathComponent("bad.zip")
        try Data("not a zip at all".utf8).write(to: url)
        XCTAssertThrowsError(try ROMStorageManager.importAny(from: url, replaceExisting: false))
    }
}
