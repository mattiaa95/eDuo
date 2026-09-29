import Foundation

/// Read-only ZIP extraction on top of the vendored minizip C sources
/// (`Vendor/minizip/unzip.c` + `ioapi.c`, exposed to Swift via the bridging
/// header). Ported from iGBA's
/// `IGBASaveBundle.extractEntriesFromZipAtURL:matchingExtensions:toDirectory:`
/// — same algorithm, called directly from Swift instead of through an
/// Objective-C wrapper since `unzip.h`'s plain C API is already visible to
/// Swift once it's in the bridging header. eDuo only ever *reads* ZIPs (ROM
/// import), so `zip.c`/`zip.h` (archive creation) were left out of the vendor
/// copy.
enum NDSZipExtractor {
    /// Largest single entry we will unpack, in bytes. A DS card tops out at
    /// 4 Gbit (512 MiB); anything claiming more is corrupt or hostile.
    private static let maxEntryBytes = 512 * 1024 * 1024

    /// Extracts every entry whose lowercased file extension is in
    /// `extensions` from the ZIP at `zipURL` into `directory` (created if
    /// needed). Skips directory entries, `__MACOSX/` resource-fork noise and
    /// dotfiles. Returns the file URLs written; two entries that share a
    /// basename (rare: same filename in different subfolders of the archive)
    /// are disambiguated with a `_2`, `_3`, ... suffix.
    static func extractEntries(fromZip zipURL: URL, matchingExtensions extensions: Set<String>, to directory: URL) -> [URL] {
        var extracted: [URL] = []
        let fm = FileManager.default

        let didStartScope = zipURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { zipURL.stopAccessingSecurityScopedResource() } }

        guard let uf = zipURL.path.withCString({ unzOpen($0) }) else {
            debugLog("NDSZipExtractor: failed to open zip at \(zipURL.path)")
            return extracted
        }
        defer { unzClose(uf) }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var status = unzGoToFirstFile(uf)
        while status == UNZ_OK {
            if let writtenURL = extractCurrentFileIfMatching(uf, extensions: extensions, into: directory, fileManager: fm) {
                extracted.append(writtenURL)
            }
            status = unzGoToNextFile(uf)
        }

        debugLog("NDSZipExtractor: extracted \(extracted.count) matching entr\(extracted.count == 1 ? "y" : "ies") from \(zipURL.lastPathComponent)")
        return extracted
    }

    /// Reads the current zip entry's metadata and, if its extension matches
    /// and it's a real file (not a directory/resource-fork/dotfile entry),
    /// decompresses it into `directory`. Returns the written file URL.
    private static func extractCurrentFileIfMatching(
        _ uf: unzFile,
        extensions: Set<String>,
        into directory: URL,
        fileManager fm: FileManager
    ) -> URL? {
        var rawName = [CChar](repeating: 0, count: 1024)
        var fileInfo = unz_file_info()
        let infoStatus = rawName.withUnsafeMutableBufferPointer { buffer -> Int32 in
            unzGetCurrentFileInfo(uf, &fileInfo, buffer.baseAddress, UInt(buffer.count - 1), nil, 0, nil, 0)
        }
        guard infoStatus == UNZ_OK else { return nil }

        let entryName = String(cString: rawName)
        let baseName = (entryName as NSString).lastPathComponent
        let ext = (baseName as NSString).pathExtension.lowercased()

        let isDirEntry = entryName.hasSuffix("/") || entryName.hasSuffix("\\")
        let isMacResource = entryName.contains("__MACOSX/")
        let isDotfile = baseName.hasPrefix(".")

        guard !isDirEntry, !isMacResource, !isDotfile, !baseName.isEmpty,
              fileInfo.uncompressed_size > 0, extensions.contains(ext) else {
            return nil
        }

        guard unzOpenCurrentFile(uf) == UNZ_OK else { return nil }
        defer { unzCloseCurrentFile(uf) }

        // uncompressed_size comes straight from the archive's own header, so a
        // corrupt or hostile .zip can declare up to 4 GB and we'd try to
        // allocate it in one go. 512 MiB is the physical ceiling of a DS card
        // (4 Gbit), so nothing legitimate is turned away.
        let size = Int(fileInfo.uncompressed_size)
        guard size <= Self.maxEntryBytes else { return nil }
        var buffer = Data(count: size)
        let bytesRead: Int32 = buffer.withUnsafeMutableBytes { raw in
            unzReadCurrentFile(uf, raw.baseAddress, UInt32(size))
        }
        guard bytesRead >= 0, Int(bytesRead) == size else { return nil }

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
