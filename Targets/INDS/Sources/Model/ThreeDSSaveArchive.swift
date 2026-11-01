import Foundation

/// Why a save could not be exported or imported. Messages are what the
/// player reads (library alerts and the 3DS pause menu share them).
enum SaveTransferError: LocalizedError {
    case noSave
    case notFormatted
    case unusable
    case notASav
    case tooLarge
    case gameRunning
    case failed

    var errorDescription: String? {
        switch self {
        case .noSave:
            return NSLocalizedString("This game has no save yet.", comment: "3DS save export")
        case .notFormatted:
            return NSLocalizedString("Start the game and save once, then import your save.", comment: "3DS save import: the game has no save yet")
        case .unusable:
            return NSLocalizedString("That isn't a save eDuo can use. Pick the folder your save manager exported, with the save files inside.", comment: "3DS save import error")
        case .notASav:
            return NSLocalizedString("Pick a .sav file (or a .zip with one inside) for this game.", comment: "DS save import error")
        case .tooLarge:
            return NSLocalizedString("That save is too large to be a game save.", comment: "Save import error")
        case .gameRunning:
            return NSLocalizedString("Quit the game before importing its save.", comment: "Save import error")
        case .failed:
            return NSLocalizedString("The save couldn't be copied. Try again in a moment.", comment: "Save transfer error")
        }
    }
}

/// Zip in / zip out and staging for 3DS saves, with no state of the core
/// (so a standalone script can exercise it: scripts/save_transfer_roundtrip.swift).
///
/// Zip creation is `NSFileCoordinator` + `.forUploading` (the system zips a
/// folder for us; its entries are prefixed with the folder name). Reading uses
/// the vendored minizip (`unz*`), the same C sources the ROM importer uses.
enum ThreeDSSaveArchive {
    /// The core keeps this beside the `00000001` data folder; the game
    /// refuses a save folder that has none. Exports carry it inside the zip
    /// so a save can land on a device that never ran the game.
    static let metadataName = "00000001.metadata"

    /// A 3DS save is a few KB to a few MB; this only stops a hostile archive.
    static let maxTotalBytes: Int64 = 256 * 1024 * 1024

    // MARK: - Export

    /// A zip named `<name>.zip` holding `name/<each item>`. The items are
    /// copied first, so the live save is never read through the coordinator.
    static func makeZip(containing items: [URL], named name: String) throws -> URL {
        let fm = FileManager.default
        let safe = sanitized(name)
        let root = fm.temporaryDirectory.appendingPathComponent("save-export", isDirectory: true)
        try? fm.removeItem(at: root)
        let wrapper = root.appendingPathComponent("src", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        do {
            try fm.createDirectory(at: wrapper, withIntermediateDirectories: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            for item in items {
                try fm.copyItem(at: item, to: wrapper.appendingPathComponent(item.lastPathComponent))
            }
        } catch {
            throw SaveTransferError.failed
        }
        let destination = out.appendingPathComponent("\(safe).zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: wrapper, options: .forUploading, error: &coordinationError) { zipURL in
            do { try fm.copyItem(at: zipURL, to: destination) } catch { copyError = error }
        }
        try? fm.removeItem(at: root.appendingPathComponent("src"))
        guard coordinationError == nil, copyError == nil, fm.fileExists(atPath: destination.path) else {
            throw SaveTransferError.failed
        }
        return destination
    }

    /// File-name safe: no separators, no control characters, never empty.
    static func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Save" : cleaned
    }

    // MARK: - Import

    /// Copies what was picked into a fresh staging folder while the picker's
    /// access lasts. Accepts a `.zip` (ours, or any save manager's), a folder
    /// (its contents count: that is what a save manager exports, e.g. `main`),
    /// or loose files. A single wrapper folder (the one `makeZip` adds) is
    /// peeled off. Throws `.unusable` when nothing usable is left.
    static func stage(from urls: [URL]) throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
        let staged = base.appendingPathComponent("save-import", isDirectory: true)
        let scratch = base.appendingPathComponent("save-import-unzip", isDirectory: true)
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: scratch)
        defer { try? fm.removeItem(at: scratch) }
        do { try fm.createDirectory(at: staged, withIntermediateDirectories: true) } catch { throw SaveTransferError.failed }

        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
            var sources: [URL]
            if isDirectory {
                sources = contents(of: unwrapped(url))
            } else if isZip(url) {
                let target = scratch.appendingPathComponent("\(index)", isDirectory: true)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try unzip(url, to: target)
                sources = contents(of: unwrapped(target))
            } else {
                sources = [url]
            }
            sources = sources.filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            for item in sources {
                do { try fm.copyItem(at: item, to: staged.appendingPathComponent(item.lastPathComponent)) } catch { throw SaveTransferError.unusable }
            }
        }
        try validate(staged)
        return staged
    }

    /// At least one non-empty file, and none of them a raw console save: a
    /// DISA container is encrypted for the console that wrote it; only a save
    /// manager's export (or ours) works.
    static func validate(_ staged: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: staged, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw SaveTransferError.unusable
        }
        var files = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            guard (values?.fileSize ?? 0) > 0 || file.lastPathComponent == metadataName else { continue }
            files += 1
            if let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 0x104),
               head.count == 0x104, head.suffix(4) == Data("DISA".utf8) {
                throw SaveTransferError.unusable
            }
        }
        guard files > 0 else { throw SaveTransferError.unusable }
    }

    /// The folder itself, or the single folder inside it when that is all
    /// it holds (`<Game> save/` made by `makeZip`, or by unzipping it).
    private static func unwrapped(_ directory: URL) -> URL {
        let entries = contents(of: directory).filter { $0.lastPathComponent != "__MACOSX" && !$0.lastPathComponent.hasPrefix(".") }
        if entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return entries[0]
        }
        return directory
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func isZip(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" { return true }
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4) else { return false }
        return head == Data([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - Unzip (tree-preserving)

    /// Unpacks every entry under `directory`, keeping folders. Entries that
    /// try to leave it (`..`, absolute paths), `__MACOSX` noise and dotfiles
    /// are skipped or refused; the total size is capped.
    static func unzip(_ zipURL: URL, to directory: URL) throws {
        guard let uf = zipURL.path.withCString({ unzOpen($0) }) else { throw SaveTransferError.unusable }
        defer { unzClose(uf) }
        var total: Int64 = 0
        var status = unzGoToFirstFile(uf)
        while status == UNZ_OK {
            try extractCurrent(uf, into: directory, total: &total)
            status = unzGoToNextFile(uf)
        }
    }

    private static func extractCurrent(_ uf: unzFile, into directory: URL, total: inout Int64) throws {
        let fm = FileManager.default
        var rawName = [CChar](repeating: 0, count: 2048)
        var info = unz_file_info()
        let infoStatus = rawName.withUnsafeMutableBufferPointer { buffer -> Int32 in
            unzGetCurrentFileInfo(uf, &info, buffer.baseAddress, UInt(buffer.count - 1), nil, 0, nil, 0)
        }
        guard infoStatus == UNZ_OK else { throw SaveTransferError.unusable }

        let name = String(cString: rawName).replacingOccurrences(of: "\\", with: "/")
        let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !components.contains("..") else { throw SaveTransferError.unusable }
        guard !components.isEmpty, !components.contains("__MACOSX"), !components.contains(where: { $0.hasPrefix(".") }) else { return }

        var destination = directory
        for component in components { destination.appendPathComponent(component) }
        guard destination.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw SaveTransferError.unusable
        }

        if name.hasSuffix("/") {
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        guard unzOpenCurrentFile(uf) == UNZ_OK else { throw SaveTransferError.unusable }
        defer { unzCloseCurrentFile(uf) }
        do { try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { throw SaveTransferError.failed }
        guard fm.createFile(atPath: destination.path, contents: nil), let out = try? FileHandle(forWritingTo: destination) else {
            throw SaveTransferError.failed
        }
        defer { try? out.close() }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = chunk.withUnsafeMutableBytes { unzReadCurrentFile(uf, $0.baseAddress, UInt32($0.count)) }
            if read < 0 { throw SaveTransferError.unusable }
            if read == 0 { break }
            total += Int64(read)
            if total > maxTotalBytes { throw SaveTransferError.tooLarge }
            do { try out.write(contentsOf: chunk.prefix(Int(read))) } catch { throw SaveTransferError.failed }
        }
    }
}
