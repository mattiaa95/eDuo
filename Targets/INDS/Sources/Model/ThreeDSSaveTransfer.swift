import Foundation

/// Export / import of a 3DS game's save, usable from the library (core not
/// running) and from the pause menu.
///
/// Where the save lives: the core keeps it under its user folder
/// (`Documents/System/`, see Native3DS/patches/0003):
///
///     sdmc/Nintendo 3DS/<id0>/<id1>/title/<high>/<low>/data/00000001/...   save files
///     sdmc/Nintendo 3DS/<id0>/<id1>/title/<high>/<low>/data/00000001.metadata
///
/// (`id0` and `id1` are 32 zeros; `high`/`low` are the two halves of the
/// program ID in 8 hex digits). `E3DSCopySaveFolder` builds exactly that from
/// `FileUtil::GetUserPath(SDMCDir)`, which sets itself up on first use, so it
/// answers before any game has booted. The program ID comes from the ROM's
/// own header (`E3DSProgramID`, Loader only, no core), and is cached per ROM
/// so the library does not reopen every image each time it builds a menu.
enum ThreeDSSaveTransfer {

    // MARK: - Locating the save

    /// 0 means the loader could not read the image; never cached.
    static func programID(for rom: ROMFile) -> UInt64? {
        // .3dsx / .z3dsx: the 3DSX loader has no program ID (the core uses 0).
        if rom.fileURL.pathExtension.lowercased().hasSuffix("3dsx") { return nil }
        let key = "\(rom.filename)_3dsProgramID"
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: key) {
            let parts = stored.components(separatedBy: "#")
            if parts.count == 2, parts[0] == rom.contentKey, let id = UInt64(parts[1], radix: 16), id != 0 { return id }
        }
        let id = E3DSProgramID(rom.fileURL.path)
        guard id != 0 else { return nil }
        defaults.set("\(rom.contentKey)#\(String(id, radix: 16))", forKey: key)
        return id
    }

    /// `.../data/00000001/` for this game.
    static func saveFolder(for rom: ROMFile) -> URL? {
        programID(for: rom).flatMap(saveFolder(forProgramID:))
    }

    static func saveFolder(forProgramID programID: UInt64) -> URL? {
        guard let path = E3DSCopySaveFolder(programID) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static func metadataURL(forFolder folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(ThreeDSSaveArchive.metadataName)
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    static func hasSave(for rom: ROMFile) -> Bool {
        guard let folder = saveFolder(for: rom) else { return false }
        return !children(of: folder).isEmpty
    }

    // MARK: - Export

    /// `<Game> save.zip` in a temp folder: the save files plus the metadata.
    static func exportArchive(for rom: ROMFile) throws -> URL {
        guard let folder = saveFolder(for: rom), !children(of: folder).isEmpty else { throw SaveTransferError.noSave }
        var items = children(of: folder)
        let metadata = metadataURL(forFolder: folder)
        if FileManager.default.fileExists(atPath: metadata.path) { items.append(metadata) }
        let name = String(format: NSLocalizedString("%@ save", comment: "Exported 3DS save folder name"), rom.displayName)
        return try ThreeDSSaveArchive.makeZip(containing: items, named: name)
    }

    // MARK: - Import

    /// Picked zip / folder / files → staging folder, checked against this game.
    static func stage(from urls: [URL], for rom: ROMFile) throws -> URL {
        let staged = try ThreeDSSaveArchive.stage(from: urls)
        guard let folder = saveFolder(for: rom) else { throw SaveTransferError.unusable }
        // The game refuses a save folder it never formatted (no metadata);
        // our own exports carry it, a save manager's do not.
        let hasMetadata = FileManager.default.fileExists(atPath: staged.appendingPathComponent(ThreeDSSaveArchive.metadataName).path)
            || FileManager.default.fileExists(atPath: metadataURL(forFolder: folder).path)
        guard hasMetadata else { throw SaveTransferError.notFormatted }
        return staged
    }

    /// Replaces the save with the staged files. The previous save is copied
    /// to `Documents/Saves/<game>.old.3dssave` (`.old2...` if taken) first.
    /// The core must not be running on this game: call it from the library, or
    /// from the pause menu once the core has stopped.
    static func install(staged: URL, for rom: ROMFile) throws {
        let fm = FileManager.default
        guard let folder = saveFolder(for: rom) else { throw SaveTransferError.unusable }
        let metadata = metadataURL(forFolder: folder)
        let stagedMetadata = staged.appendingPathComponent(ThreeDSSaveArchive.metadataName)
        let carriesMetadata = fm.fileExists(atPath: stagedMetadata.path)
        guard carriesMetadata || fm.fileExists(atPath: metadata.path) else { throw SaveTransferError.notFormatted }

        keepCopyOfCurrentSave(for: rom, folder: folder, metadata: metadata)

        // The live save steps aside (a rename, same volume) instead of being
        // deleted up front, and comes back if anything below fails, so an
        // error or a kill mid-install never leaves the game without a save.
        let aside = folder.deletingLastPathComponent().appendingPathComponent(".import-previous", isDirectory: true)
        let metadataAside = folder.deletingLastPathComponent().appendingPathComponent(".import-previous.metadata")
        try? fm.removeItem(at: aside)
        try? fm.removeItem(at: metadataAside)
        let hadFolder = fm.fileExists(atPath: folder.path)
        do {
            if hadFolder { try fm.moveItem(at: folder, to: aside) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in children(of: staged) where item.lastPathComponent != ThreeDSSaveArchive.metadataName {
                try fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
            if carriesMetadata {
                if fm.fileExists(atPath: metadata.path) { try fm.moveItem(at: metadata, to: metadataAside) }
                try fm.moveItem(at: stagedMetadata, to: metadata)
            }
        } catch {
            if hadFolder {
                try? fm.removeItem(at: folder)
                try? fm.moveItem(at: aside, to: folder)
            }
            if fm.fileExists(atPath: metadataAside.path) {
                try? fm.removeItem(at: metadata)
                try? fm.moveItem(at: metadataAside, to: metadata)
            }
            throw SaveTransferError.failed
        }
        try? fm.removeItem(at: aside)
        try? fm.removeItem(at: metadataAside)
        try? fm.removeItem(at: staged)
    }

    private static func keepCopyOfCurrentSave(for rom: ROMFile, folder: URL, metadata: URL) {
        let fm = FileManager.default
        var items = children(of: folder)
        if fm.fileExists(atPath: metadata.path) { items.append(metadata) }
        guard !items.isEmpty, let saves = try? ROMStorageManager.savesDirectoryURL() else { return }
        var counter = 1
        var target = saves.appendingPathComponent("\(rom.baseName).old.3dssave", isDirectory: true)
        while fm.fileExists(atPath: target.path) {
            counter += 1
            target = saves.appendingPathComponent("\(rom.baseName).old\(counter).3dssave", isDirectory: true)
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for item in items { try fm.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent)) }
        } catch {
            debugLog("Could not keep a copy of the 3DS save for \(rom.baseName): \(error.localizedDescription)")
        }
    }
}

/// One entry point for the library's Export Save / Import Save on both
/// handhelds (DS: the `.sav` in `Documents/Saves`; 3DS: see above).
enum ROMSaveTransfer {
    /// False for 3DS homebrew (.3dsx): it has no program ID (the core runs it
    /// as title 0000000000000000) and keeps its data in its own sdmc:/ folder,
    /// never in a title save folder, so there is nothing to export or import.
    static func supportsTransfer(_ rom: ROMFile) -> Bool {
        !rom.isThreeDS || ThreeDSSaveTransfer.programID(for: rom) != nil
    }

    static func hasSave(_ rom: ROMFile) -> Bool {
        rom.isThreeDS ? ThreeDSSaveTransfer.hasSave(for: rom) : rom.hasSaveFile
    }

    /// A file to hand to the share sheet.
    static func exportFile(for rom: ROMFile) throws -> URL {
        if rom.isThreeDS { return try ThreeDSSaveTransfer.exportArchive(for: rom) }
        guard let save = rom.saveFileURL, rom.hasSaveFile else { throw SaveTransferError.noSave }
        return save
    }

    static func stageImport(from urls: [URL], for rom: ROMFile) throws -> URL {
        if rom.isThreeDS {
            guard !E3DSIsRunning() else { throw SaveTransferError.gameRunning }
            return try ThreeDSSaveTransfer.stage(from: urls, for: rom)
        }
        // DS: one `.sav` (any name: it is matched to this game by the player's
        // choice, not by file name), or a zip with one inside.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("save-import-ds", isDirectory: true)
        try? fm.removeItem(at: dir)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw SaveTransferError.failed }
        guard urls.count == 1, let url = urls.first else { throw SaveTransferError.notASav }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let staged = dir.appendingPathComponent("\(rom.baseName).sav")
        switch url.pathExtension.lowercased() {
        case "sav":
            do { try fm.copyItem(at: url, to: staged) } catch { throw SaveTransferError.failed }
        case "zip":
            let found = NDSZipExtractor.extractEntries(fromZip: url, matchingExtensions: ["sav"], to: dir.appendingPathComponent("zip", isDirectory: true))
            guard found.count == 1, let one = found.first else { throw SaveTransferError.notASav }
            do { try fm.moveItem(at: one, to: staged) } catch { throw SaveTransferError.failed }
        default:
            throw SaveTransferError.notASav
        }
        let size = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw SaveTransferError.notASav }
        return staged
    }

    /// Replaces the game's save with what `stageImport` produced, keeping the
    /// previous one as `<name>.old.sav` (`.old2...`), like a replaced ROM does.
    static func installImport(_ staged: URL, for rom: ROMFile) throws {
        if rom.isThreeDS {
            guard !E3DSIsRunning() else { throw SaveTransferError.gameRunning }
            return try ThreeDSSaveTransfer.install(staged: staged, for: rom)
        }
        let fm = FileManager.default
        guard let save = rom.saveFileURL else { throw SaveTransferError.failed }
        if fm.fileExists(atPath: save.path) {
            var counter = 1
            var target = INDSSaveBackup.saveURL(baseName: "\(rom.baseName).old")
            while let candidate = target, fm.fileExists(atPath: candidate.path) {
                counter += 1
                target = INDSSaveBackup.saveURL(baseName: "\(rom.baseName).old\(counter)")
            }
            if let target { try? fm.copyItem(at: save, to: target) }
        }
        do {
            try fm.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: save.path) {
                _ = try fm.replaceItemAt(save, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: save)
            }
        } catch {
            throw SaveTransferError.failed
        }
    }
}
