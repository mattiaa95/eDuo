import Foundation

/// Read-only `.7z` extraction on top of the vendored LZMA SDK (public
/// domain, `Vendor/lzma/`) via the flat-C `Sz7zShim` (`Sz7zShim.h`/`.c`,
/// exposed to Swift through the bridging header). Same contract and shape
/// as `NDSZipExtractor` — read that one first — so `ROMStorageManager` can
/// treat `.zip` and `.7z` imports identically: eDuo only ever *reads*
/// `.7z` archives (ROM import), never writes them, so none of the SDK's
/// encoder sources were vendored.
enum NDS7zExtractor {
    /// Entries larger than this, uncompressed, are skipped rather than
    /// decompressed — a cheap guard against a "decompression bomb" entry
    /// (LZMA's compression ratio can be extreme, more so than deflate)
    /// inside an otherwise-tiny `.7z`. Mirrors `ROMStorageManager`'s own
    /// `maxROMSize`; any real `.nds`/`.sav` is well under this. The shim
    /// applies the same cap to the entry's whole solid block
    /// (`kSz7zMaxFolderUnpackSize`), which is what actually gets decoded.
    private static let maxDecompressedEntrySize: UInt64 = 512 * 1024 * 1024

    /// Extracts every entry whose lowercased file extension is in
    /// `extensions` from the `.7z` at `sevenZipURL` into `directory`
    /// (created if needed). Skips directory entries, `__MACOSX/`
    /// resource-fork noise, dotfiles, and anything over
    /// `maxDecompressedEntrySize`. Returns the file URLs written; two
    /// entries that share a basename are disambiguated with a `_2`, `_3`,
    /// ... suffix — same as `NDSZipExtractor`.
    ///
    /// Never throws. A corrupt/malformed `.7z`, or one that leans on a
    /// codec this SDK subset doesn't carry — AES-256 encryption in
    /// particular, see `Sz7zShim.h` — simply yields fewer, possibly zero,
    /// extracted URLs, exactly like a bad entry inside an otherwise-good
    /// `.zip` does.
    static func extractEntries(from7z sevenZipURL: URL, matchingExtensions extensions: Set<String>, to directory: URL) -> [URL] {
        var extracted: [URL] = []
        let fm = FileManager.default

        let didStartScope = sevenZipURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { sevenZipURL.stopAccessingSecurityScopedResource() } }

        guard let archive = sevenZipURL.path.withCString({ Sz7zArchive_Open($0) }) else {
            debugLog("NDS7zExtractor: failed to open .7z at \(sevenZipURL.path)")
            return extracted
        }
        defer { Sz7zArchive_Close(archive) }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let numFiles = Sz7zArchive_GetNumFiles(archive)
        for index in 0..<numFiles {
            if let writtenURL = extractEntryIfMatching(archive, index: index, extensions: extensions, into: directory, fileManager: fm) {
                extracted.append(writtenURL)
            }
        }

        debugLog("NDS7zExtractor: extracted \(extracted.count) matching entr\(extracted.count == 1 ? "y" : "ies") from \(sevenZipURL.lastPathComponent)")
        return extracted
    }

    /// Reads entry `index`'s metadata and, if its extension matches and
    /// it's a real, reasonably-sized file (not a directory/resource-fork/
    /// dotfile entry, not over `maxDecompressedEntrySize`), decompresses it
    /// into `directory`. Returns the written file URL, or `nil` for
    /// anything skipped *or* that failed to decompress — unsupported
    /// codec, CRC mismatch, OOM. `Sz7zArchive_ExtractToBuffer` never
    /// crashes on bad input, it just reports failure.
    private static func extractEntryIfMatching(
        _ archive: OpaquePointer,
        index: UInt32,
        extensions: Set<String>,
        into directory: URL,
        fileManager fm: FileManager
    ) -> URL? {
        guard Sz7zArchive_IsDir(archive, index) == 0 else { return nil }

        var utf16Ptr: UnsafeMutablePointer<UInt16>?
        var utf16Count = 0
        guard Sz7zArchive_CopyFileNameUTF16(archive, index, &utf16Ptr, &utf16Count) != 0,
              let namePtr = utf16Ptr else {
            return nil
        }
        let entryName = String(decoding: UnsafeBufferPointer(start: namePtr, count: utf16Count), as: UTF16.self)
        Sz7zArchive_FreeMemory(namePtr)

        let baseName = (entryName as NSString).lastPathComponent
        let ext = (baseName as NSString).pathExtension.lowercased()

        // Entry names are basename-only from here on (see `baseName` above),
        // so a malicious "../../etc/whatever" path inside the archive can
        // only ever resolve to "whatever" under `directory` — no traversal.
        let isMacResource = entryName.contains("__MACOSX/") || entryName.contains("__MACOSX\\")
        let isDotfile = baseName.hasPrefix(".")

        guard !isMacResource, !isDotfile, !baseName.isEmpty, extensions.contains(ext) else {
            return nil
        }

        let uncompressedSize = Sz7zArchive_GetFileSize(archive, index)
        guard uncompressedSize > 0, uncompressedSize <= maxDecompressedEntrySize else { return nil }

        var dataPtr: UnsafeMutablePointer<UInt8>?
        var dataSize = 0
        guard Sz7zArchive_ExtractToBuffer(archive, index, &dataPtr, &dataSize) != 0,
              let bytes = dataPtr else {
            return nil
        }
        // The shim hands over a malloc'd copy of the entry (its decoded solid
        // block stays cached in the handle for the next entry). Wrap it
        // without copying again and let `Data` free it: a second copy would
        // add a third 512 MB peak on top of block + entry, exactly the sort
        // of spike that gets a background import jetsammed.
        let buffer = Data(bytesNoCopy: UnsafeMutableRawPointer(bytes), count: dataSize,
                          deallocator: .custom { pointer, _ in Sz7zArchive_FreeMemory(pointer) })

        var destination = directory.appendingPathComponent(baseName)
        let stem = (baseName as NSString).deletingPathExtension
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            destination = directory.appendingPathComponent(candidate)
            counter += 1
        }

        guard (try? buffer.write(to: destination, options: .atomic)) != nil else { return nil }
        return destination
    }
}
