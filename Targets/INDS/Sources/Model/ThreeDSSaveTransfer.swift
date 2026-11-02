import Foundation

/// Where a 3DS game's save lives, plus Export / Import (usable from the
/// library with the core stopped, and from the pause menu).
///
/// Like a DS `.sav`, the save is a plain item in `Documents/Saves`, visible in
/// Files › eDuo › Saves: the core writes it straight into an app-chosen
/// "container" (`E3DSSetSaveDataFolder`, see `ThreeDSGameViewController.startIfNeeded`):
///
///     Documents/Saves/<name>.3dssave/00000001/            the save files
///     Documents/Saves/<name>.3dssave/00000001.metadata    mirrors the stock `data/` folder
///
/// Builds up to 1.2.0 (64) left it in the core's own SD layout
/// (`Documents/System/sdmc/Nintendo 3DS/<0s>/<0s>/title/<hi>/<lo>/data/00000001/` +
/// `data/00000001.metadata`, `E3DSCopyLegacySaveFolder`); `prepareContainer` moves
/// such a save into the container the first time the game is opened or looked at.
///
/// Which folder a game uses (`container(programID:baseName:)`), in this order:
///  a. `<baseName>.3dssave` exists and the registry (UserDefaults `eDuo3DSSaveFolders`,
///     folder name -> program ID) has no entry for it or one for this program ID: that
///     one, registered. This is what makes a folder copied in from another device work
///     with nothing imported.
///  b. Else a registered folder of this same program ID that exists: two images of one
///     game (a .3ds and a .cia) share the first one's folder, as the old core folder,
///     keyed by program ID, did.
///  c. Else, `<baseName>.3dssave` exists but belongs to a different program ID (another
///     game once had this file name, e.g. Replace ROM): `<baseName> (<16 hex ID>).3dssave`,
///     so the other game's folder is never touched.
///  d. Else `<baseName>.3dssave`, registered but not created: the core makes it on the
///     game's first save, resolving never creates empty folders.
/// The program ID comes from the ROM's own header (`E3DSProgramID`, Loader only, no core)
/// and is cached per ROM so the library does not reopen every image each time it builds
/// a menu.
enum ThreeDSSaveTransfer {

    // MARK: - Locating the save

    static let containerExtension = "3dssave"
    private static let saveSubfolder = "00000001"
    private static let registryKey = "eDuo3DSSaveFolders"
    private static let registryLock = NSLock()

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

    private static func idString(_ programID: UInt64) -> String { String(format: "%016llX", programID) }

    // The registry: folder name (no extension) -> program ID. Callers hold `registryLock`.
    private static func loadRegistry() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: registryKey) as? [String: String] ?? [:]
    }

    private static func storeRegistry(_ registry: [String: String]) {
        UserDefaults.standard.set(registry, forKey: registryKey)
    }

    /// The registered program ID (16 hex digits) of a folder name, if any.
    static func registeredID(forFolderName name: String) -> String? {
        registryLock.lock(); defer { registryLock.unlock() }
        return loadRegistry()[name]
    }

    static func forgetRegistration(ofFolderName name: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        var registry = loadRegistry()
        guard registry.removeValue(forKey: name) != nil else { return }
        storeRegistry(registry)
    }

    private static func folderURL(_ name: String, in saves: URL) -> URL {
        saves.appendingPathComponent("\(name).\(containerExtension)", isDirectory: true)
    }

    /// Rules a-d above, no side effects. Callers hold `registryLock`.
    private static func resolveName(programID: UInt64, baseName: String, saves: URL, registry: [String: String]) -> String {
        let fm = FileManager.default
        let id = idString(programID)
        let baseExists = fm.fileExists(atPath: folderURL(baseName, in: saves).path)
        if baseExists, registry[baseName] == nil || registry[baseName] == id { return baseName }
        for name in registry.keys.sorted() where registry[name] == id && fm.fileExists(atPath: folderURL(name, in: saves).path) {
            return name
        }
        return baseExists ? "\(baseName) (\(id))" : baseName
    }

    /// `Saves/<name>.3dssave/` for this game (see the rules above). With `prepare`
    /// (and no core running) the folder is also brought to the current layout and a
    /// legacy save is migrated into it, and the choice is registered. `prepare: false`
    /// is for callers that only need the name (delete, rename).
    static func container(programID: UInt64, baseName: String, prepare: Bool = true) -> URL? {
        guard let saves = try? ROMStorageManager.savesDirectoryURL() else { return nil }
        registryLock.lock()
        var registry = loadRegistry()
        let name = resolveName(programID: programID, baseName: baseName, saves: saves, registry: registry)
        let url = folderURL(name, in: saves)
        if prepare, registry[name] != idString(programID) {
            registry[name] = idString(programID)
            storeRegistry(registry)
        }
        registryLock.unlock()
        if prepare, !E3DSIsRunning() {
            prepareContainer(programID: programID, name: name, container: url, saves: saves)
        }
        return url
    }

    /// nil for .3dsx / an unreadable program ID.
    static func container(for rom: ROMFile, prepare: Bool = true) -> URL? {
        programID(for: rom).flatMap { container(programID: $0, baseName: rom.baseName, prepare: prepare) }
    }

    /// `<container>/00000001/`: the save files.
    static func saveFolder(for rom: ROMFile) -> URL? {
        container(for: rom)?.appendingPathComponent(saveSubfolder, isDirectory: true)
    }

    static func metadataURL(forFolder folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(ThreeDSSaveArchive.metadataName)
    }

    /// Where builds up to 1.2.0 kept the save: `.../data/00000001/` (its metadata sits beside it).
    static func legacySaveFolder(forProgramID programID: UInt64) -> URL? {
        guard let path = E3DSCopyLegacySaveFolder(programID) else { return nil }
        defer { free(path) }
        var string = String(cString: path)
        while string.count > 1, string.hasSuffix("/") { string.removeLast() }
        return URL(fileURLWithPath: string, isDirectory: true)
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    private static func visibleChildren(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    static func hasSave(for rom: ROMFile) -> Bool {
        guard let folder = saveFolder(for: rom) else { return false }
        return !visibleChildren(of: folder).isEmpty
    }

    // MARK: - Layout and migration

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Removes a folder only if it holds nothing at all.
    private static func removeIfEmpty(_ url: URL) -> Bool {
        guard isDirectory(url), children(of: url).isEmpty else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Newest modification date of any file under `folder`, and of the metadata file.
    private static func latestModification(folder: URL, metadata: URL) -> Date {
        let fm = FileManager.default
        var latest = Date.distantPast
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        if let items = fm.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in items {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true, let date = values?.contentModificationDate, date > latest { latest = date }
            }
        }
        if let date = (try? metadata.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > latest {
            latest = date
        }
        return latest
    }

    /// `Saves/<name>.old.3dssave` (`.old2...` if taken), not created.
    private static func freeOldURL(name: String, saves: URL) -> URL {
        let fm = FileManager.default
        var counter = 1
        var target = folderURL("\(name).old", in: saves)
        while fm.fileExists(atPath: target.path) {
            counter += 1
            target = folderURL("\(name).old\(counter)", in: saves)
        }
        return target
    }

    /// A save = `<folder>` (files) + its metadata file; moves both (a rename, same
    /// volume). If the metadata cannot follow, the files go back. False = nothing changed.
    private static func moveSave(folder: URL, metadata: URL, toFolder: URL, toMetadata: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: toFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: toFolder.path), !removeIfEmpty(toFolder) {
                debugLog("3DS save: \(toFolder.path) is not empty, nothing moved")
                return false
            }
            try fm.moveItem(at: folder, to: toFolder)
        } catch {
            debugLog("3DS save: could not move \(folder.path): \(error.localizedDescription)")
            return false
        }
        guard fm.fileExists(atPath: metadata.path) else { return true }
        do {
            if fm.fileExists(atPath: toMetadata.path) {
                // Belongs to an empty save, which the move above just replaced.
                _ = try fm.replaceItemAt(toMetadata, withItemAt: metadata)
            } else {
                try fm.moveItem(at: metadata, to: toMetadata)
            }
        } catch {
            debugLog("3DS save: could not move \(metadata.path): \(error.localizedDescription); putting the files back")
            try? fm.moveItem(at: toFolder, to: folder)
            return false
        }
        return true
    }

    /// Brings a container to the current layout, then migrates a legacy save (build 64 or older) into it.
    /// Loss-free and idempotent; only runs with the core stopped.
    private static func prepareContainer(programID: UInt64, name: String, container: URL, saves: URL) {
        normalizeFlatLayout(container)
        migrateLegacySave(programID: programID, name: name, container: container, saves: saves)
    }

    /// Our Export zip (and a `.old.3dssave` copy from before the layout change) is
    /// flat: save files + `00000001.metadata`. Wraps the files in `00000001/`.
    private static func normalizeFlatLayout(_ container: URL) {
        let fm = FileManager.default
        let files = container.appendingPathComponent(saveSubfolder, isDirectory: true)
        guard isDirectory(container), !fm.fileExists(atPath: files.path),
              fm.fileExists(atPath: container.appendingPathComponent(ThreeDSSaveArchive.metadataName).path) else { return }
        let items = visibleChildren(of: container).filter { $0.lastPathComponent != ThreeDSSaveArchive.metadataName }
        var moved: [(from: URL, to: URL)] = []
        do {
            try fm.createDirectory(at: files, withIntermediateDirectories: false)
            for item in items {
                let target = files.appendingPathComponent(item.lastPathComponent)
                try fm.moveItem(at: item, to: target)
                moved.append((item, target))
            }
            debugLog("3DS save: wrapped \(items.count) item(s) of \(container.lastPathComponent) in \(saveSubfolder)/")
        } catch {
            debugLog("3DS save: could not normalize \(container.lastPathComponent): \(error.localizedDescription); undoing")
            for pair in moved.reversed() { try? fm.moveItem(at: pair.to, to: pair.from) }
            _ = removeIfEmpty(files)
        }
    }

    private static func migrateLegacySave(programID: UInt64, name: String, container: URL, saves: URL) {
        guard let legacyFiles = legacySaveFolder(forProgramID: programID),
              !visibleChildren(of: legacyFiles).isEmpty else { return }
        let legacyData = legacyFiles.deletingLastPathComponent()
        let legacyMetadata = metadataURL(forFolder: legacyFiles)
        let files = container.appendingPathComponent(saveSubfolder, isDirectory: true)
        let metadata = metadataURL(forFolder: files)

        func finish(_ what: String) {
            _ = removeIfEmpty(legacyData)
            debugLog("3DS save: \(what) (program \(idString(programID)) -> \(container.lastPathComponent))")
        }

        if visibleChildren(of: files).isEmpty {
            if moveSave(folder: legacyFiles, metadata: legacyMetadata, toFolder: files, toMetadata: metadata) {
                finish("migrated the legacy save")
            }
            return
        }

        // Both sides have a save: the one touched last stays live, the other is kept aside.
        let containerDate = latestModification(folder: files, metadata: metadata)
        let legacyDate = latestModification(folder: legacyFiles, metadata: legacyMetadata)
        let old = freeOldURL(name: name, saves: saves)
        let oldFiles = old.appendingPathComponent(saveSubfolder, isDirectory: true)
        let oldMetadata = metadataURL(forFolder: oldFiles)
        if legacyDate > containerDate {
            guard moveSave(folder: files, metadata: metadata, toFolder: oldFiles, toMetadata: oldMetadata) else { return }
            if moveSave(folder: legacyFiles, metadata: legacyMetadata, toFolder: files, toMetadata: metadata) {
                finish("legacy save is newer, replaced the container's; the previous one is in \(old.lastPathComponent)")
            } else {
                _ = moveSave(folder: oldFiles, metadata: oldMetadata, toFolder: files, toMetadata: metadata)
                _ = removeIfEmpty(old)
                debugLog("3DS save: could not install the legacy save, left both in place")
            }
        } else if moveSave(folder: legacyFiles, metadata: legacyMetadata, toFolder: oldFiles, toMetadata: oldMetadata) {
            finish("container is newer, the legacy save is kept in \(old.lastPathComponent)")
        }
    }

    // MARK: - Delete / rename (called by ROMStorageManager)

    /// "Delete ROM + Save Data": the container, its registry entry and a leftover legacy
    /// folder. The caller checks that no other ROM shares this program ID. Never touches
    /// `.old.3dssave` copies (the DS keeps `.old.sav` too).
    static func deleteSave(programID: UInt64, baseName: String) {
        let fm = FileManager.default
        if let saves = try? ROMStorageManager.savesDirectoryURL() {
            registryLock.lock()
            let name = resolveName(programID: programID, baseName: baseName, saves: saves, registry: loadRegistry())
            registryLock.unlock()
            let url = folderURL(name, in: saves)
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url); debugLog("3DS save: deleted \(url.lastPathComponent)") }
                catch { debugLog("3DS save: could not delete \(url.lastPathComponent): \(error.localizedDescription)") }
            }
            forgetRegistration(ofFolderName: name)
        }
        if let legacy = legacySaveFolder(forProgramID: programID) {
            let data = legacy.deletingLastPathComponent()
            if fm.fileExists(atPath: data.path) {
                do { try fm.removeItem(at: data); debugLog("3DS save: deleted the legacy folder for \(idString(programID))") }
                catch { debugLog("3DS save: could not delete \(data.path): \(error.localizedDescription)") }
            }
        }
    }

    /// Rename: the container to move, if it is named after `oldBaseName` and exists
    /// (a container shared with another ROM's name stays put). Throws when
    /// `<new>.3dssave` is already there, like a `.sav` under the target name.
    static func renamePlan(programID: UInt64, from oldBaseName: String, to newBaseName: String) throws -> (from: URL, to: URL)? {
        guard let saves = try? ROMStorageManager.savesDirectoryURL() else { return nil }
        registryLock.lock()
        let name = resolveName(programID: programID, baseName: oldBaseName, saves: saves, registry: loadRegistry())
        registryLock.unlock()
        let from = folderURL(oldBaseName, in: saves)
        guard name == oldBaseName, FileManager.default.fileExists(atPath: from.path) else { return nil }
        let to = folderURL(newBaseName, in: saves)
        if FileManager.default.fileExists(atPath: to.path) {
            throw ROMStorageError.duplicateFile(to.lastPathComponent)
        }
        return (from, to)
    }

    /// The registry follows a container that was moved from `old` to `new`.
    static func didRename(programID: UInt64, from oldBaseName: String, to newBaseName: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        var registry = loadRegistry()
        registry.removeValue(forKey: oldBaseName)
        registry[newBaseName] = idString(programID)
        storeRegistry(registry)
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
    /// to `Documents/Saves/<name>.old.3dssave` (`.old2...` if taken) first, in the
    /// container layout.
    /// The core must not be running on this game: call it from the library, or
    /// from the pause menu once the core has stopped.
    static func install(staged: URL, for rom: ROMFile) throws {
        let fm = FileManager.default
        guard let folder = saveFolder(for: rom) else { throw SaveTransferError.unusable }
        let metadata = metadataURL(forFolder: folder)
        let stagedMetadata = staged.appendingPathComponent(ThreeDSSaveArchive.metadataName)
        let carriesMetadata = fm.fileExists(atPath: stagedMetadata.path)
        guard carriesMetadata || fm.fileExists(atPath: metadata.path) else { throw SaveTransferError.notFormatted }

        keepCopyOfCurrentSave(folder: folder, metadata: metadata)

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

    /// Copy of the live save as `Saves/<name>.old.3dssave` in the container layout
    /// (`00000001/` + `00000001.metadata`), so renaming it to `<name>.3dssave` makes it live.
    private static func keepCopyOfCurrentSave(folder: URL, metadata: URL) {
        let fm = FileManager.default
        let hasFiles = !children(of: folder).isEmpty
        let hasMetadata = fm.fileExists(atPath: metadata.path)
        guard hasFiles || hasMetadata, let saves = try? ROMStorageManager.savesDirectoryURL() else { return }
        let name = folder.deletingLastPathComponent().deletingPathExtension().lastPathComponent
        let target = freeOldURL(name: name, saves: saves)
        let targetFiles = target.appendingPathComponent(saveSubfolder, isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            if hasFiles { try fm.copyItem(at: folder, to: targetFiles) }
            if hasMetadata { try fm.copyItem(at: metadata, to: metadataURL(forFolder: targetFiles)) }
        } catch {
            debugLog("Could not keep a copy of the 3DS save for \(name): \(error.localizedDescription)")
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
