import Foundation

enum ROMStorageError: LocalizedError {
    case unsupportedFileType(String)
    case duplicateFile(String)
    case invalidROM(String)
    case emptyFile
    case fileTooLarge
    case unavailableDocumentsDirectory
    case noMatchingROM(String)
    case zipContainsNoSupportedFiles
    case invalidName
    case notEnoughSpace
    case romInUse(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return String(
                format: NSLocalizedString(
                    "Unsupported file type .%1$@. Import a game file, a .zip/.7z/.gz archive, or a .sav save file.",
                    comment: "Import Failed alert: the user picked a file whose extension the importer doesn't accept. %1$@ is the file extension."
                ),
                ext
            )
        case .duplicateFile(let name):
            return String(
                format: NSLocalizedString(
                    "\"%1$@\" already exists in your library.",
                    comment: "Import Failed alert: the user imported or renamed a file to a name already present in the library. %1$@ is the filename."
                ),
                name
            )
        case .invalidROM(let reason):
            return String(
                format: NSLocalizedString(
                    "Invalid ROM. %1$@",
                    comment: "Import Failed alert: the user imported a .nds file that failed header validation. %1$@ is the reason."
                ),
                reason
            )
        case .emptyFile:
            return NSLocalizedString(
                "The selected file is empty.",
                comment: "Import Failed alert: the user imported a zero-byte ROM or save file."
            )
        case .fileTooLarge:
            return NSLocalizedString(
                "This file is too large to be a ROM.",
                comment: "Import Failed alert: the user imported a ROM bigger than the supported size limit."
            )
        case .unavailableDocumentsDirectory:
            return NSLocalizedString(
                "The app documents directory is unavailable.",
                comment: "Import Failed alert: the app could not reach its own storage folder while importing."
            )
        case .noMatchingROM(let name):
            return String(
                format: NSLocalizedString(
                    "No game named \"%1$@\" was found. Import the game before its save file.",
                    comment: "Import Failed alert: the user imported a .sav save file with no matching ROM in the library. %1$@ is the save file's base name."
                ),
                name
            )
        case .zipContainsNoSupportedFiles:
            return NSLocalizedString(
                "This archive doesn't contain any game or save files.",
                comment: "Import Failed alert: the user imported a .zip/.7z/.gz archive with nothing usable inside."
            )
        case .invalidName:
            return NSLocalizedString(
                "Enter a valid name.",
                comment: "Import Failed alert: the user confirmed a ROM rename with an empty or invalid name."
            )
        case .notEnoughSpace:
            return NSLocalizedString(
                "Not enough free space on this device. Free some up and try again.",
                comment: "Import Failed alert: the device does not have room for the file being imported."
            )
        case .romInUse(let name):
            return String(
                format: NSLocalizedString(
                    "\"%1$@\" is open in another window. Close it first.",
                    comment: "Alert: the user tried to rename, delete or replace a ROM that is running in another iPad window. %1$@ is the ROM's name."
                ),
                name
            )
        }
    }
}

/// What to do when an imported ROM's name is already in the library.
/// `ifSameGame` is the external "Open in eDuo" policy: a byte-identical
/// header and size is the same game re-imported and can replace silently;
/// anything else (a hack or a different game that happens to share the
/// filename) asks first, because the existing save states would otherwise
/// be resumed into the wrong ROM.
enum ROMReplacePolicy {
    case never
    case always
    case ifSameGame
}

/// What a single `importAny(from:replaceExisting:)` call produced. A plain
/// `.nds`/`.sav` import always yields exactly one URL (or throws); a `.zip`
/// or `.7z` archive can yield several, and can partially fail (e.g. one
/// duplicate among five ROMs) without the whole import throwing — those
/// per-entry problems are collected in `failureMessages` instead.
struct ROMImportResult {
    var importedROMURLs: [URL] = []
    var importedSaveURLs: [URL] = []
    var failureMessages: [String] = []
}

enum ROMStorageManager {
    private static let romsFolderName = "ROMs"
    private static let biosFolderName = "BIOS"
    private static let savesFolderName = "Saves"
    private static let maxROMSize: Int64 = 512 * 1024 * 1024
    private static let saveExtension = "sav"
    private static let zipROMExtensions: Set<String> = ["nds"]
    private static let zipSaveExtensions: Set<String> = ["sav"]
    private static let importTempPrefix = "ROMImport-"

    static func romsDirectoryURL() throws -> URL {
        try directoryURL(named: romsFolderName)
    }

    static func biosDirectoryURL() throws -> URL {
        try directoryURL(named: biosFolderName)
    }

    /// `Documents/Saves` — matches `MelonDSCoreBridge.mm`'s own battery-save
    /// convention (`Documents/Saves/<romBaseName>.sav`) exactly, so a save
    /// imported here is picked up the next time the ROM loads.
    static func savesDirectoryURL() throws -> URL {
        try directoryURL(named: savesFolderName)
    }

    static func listROMs() throws -> [ROMFile] {
        let directory = try romsDirectoryURL()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { $0.pathExtension.lowercased() == "nds" }
            .map { url in
                let values = try url.resourceValues(forKeys: [.creationDateKey])
                return ROMFile(fileURL: url, creationDate: values.creationDate ?? .distantPast)
            }
    }

    // MARK: - Import (dispatch by extension)

    /// Single entry point for every import surface (the "+" file importer,
    /// external `onOpenURL`): dispatches on `sourceURL`'s extension to the
    /// right handler. `.nds`/`.sav` throw on failure (duplicate, no matching
    /// ROM, ...); `.zip`/`.7z` never throw for individual bad entries inside
    /// them — those are reported in `ROMImportResult.failureMessages` — but
    /// do throw `zipContainsNoSupportedFiles` if the archive contains
    /// nothing usable at all.
    @discardableResult
    static func importAny(from sourceURL: URL, replaceExisting: Bool) throws -> ROMImportResult {
        try importAny(from: sourceURL, replacePolicy: replaceExisting ? .always : .never)
    }

    /// `replacePolicy` applies to ROMs; a battery save only ever replaces an
    /// existing one under `.always` (the user's explicit "Replace").
    @discardableResult
    static func importAny(from sourceURL: URL, replacePolicy: ROMReplacePolicy) throws -> ROMImportResult {
        switch sourceURL.pathExtension.lowercased() {
        case "nds":
            let url = try importROM(from: sourceURL, replacePolicy: replacePolicy)
            return ROMImportResult(importedROMURLs: [url])
        case "zip":
            return try importROMsFromArchive(at: sourceURL, replacePolicy: replacePolicy) {
                NDSZipExtractor.extractEntries(fromZip: $0, matchingExtensions: $1, to: $2)
            }
        case "7z":
            return try importROMsFromArchive(at: sourceURL, replacePolicy: replacePolicy) {
                NDS7zExtractor.extractEntries(from7z: $0, matchingExtensions: $1, to: $2)
            }
        case "gz":
            return try importROMsFromArchive(at: sourceURL, replacePolicy: replacePolicy) {
                NDSGzExtractor.extractEntries(fromGz: $0, matchingExtensions: $1, to: $2)
            }
        case saveExtension:
            let url = try importSave(from: sourceURL, replaceExisting: replacePolicy == .always)
            return ROMImportResult(importedSaveURLs: [url])
        case let ext:
            throw ROMStorageError.unsupportedFileType(ext.isEmpty ? "unknown" : ext)
        }
    }

    // MARK: - Open ROMs

    /// Base names of ROMs currently on screen in an emulation view, counted
    /// per window. iPad multi-window can show the library in one window while
    /// another runs a game: renaming or deleting that game's files under a
    /// live core would leave it writing `<old>.sav` and states nobody lists.
    /// Registered by `EmulationView` (appear/disappear), consulted by
    /// `renameROM`, `deleteROM` and the replace branch of `importROM`.
    private static let openLock = NSLock()
    private static var openCounts: [String: Int] = [:]

    static func markOpen(baseName: String) {
        openLock.lock(); defer { openLock.unlock() }
        openCounts[baseName, default: 0] += 1
    }

    static func markClosed(baseName: String) {
        openLock.lock(); defer { openLock.unlock() }
        guard let count = openCounts[baseName] else { return }
        if count <= 1 {
            openCounts.removeValue(forKey: baseName)
        } else {
            openCounts[baseName] = count - 1
        }
    }

    static func isOpen(baseName: String) -> Bool {
        openLock.lock(); defer { openLock.unlock() }
        return (openCounts[baseName] ?? 0) > 0
    }

    /// Headroom left free on top of the file itself. Filling the disk
    /// completely does not just break the import: it breaks the auto-save and
    /// the save states of the game already running, which is far worse.
    private static let freeSpaceMargin: Int64 = 100 * 1024 * 1024

    /// `false` only when we know it does not fit. If the system will not give
    /// the number, nothing is blocked: better to let the copy fail with its
    /// real error than to refuse a legitimate import for lack of a measurement.
    static func hasRoom(forBytes bytes: Int64) -> Bool {
        guard let docs = try? romsDirectoryURL(),
              let free = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                  .volumeAvailableCapacityForImportantUsage else { return true }
        return free > bytes + freeSpaceMargin
    }

    @discardableResult
    static func importROM(from sourceURL: URL, replaceExisting: Bool) throws -> URL {
        try importROM(from: sourceURL, replacePolicy: replaceExisting ? .always : .never)
    }

    @discardableResult
    static func importROM(from sourceURL: URL, replacePolicy: ROMReplacePolicy) throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "nds" else {
            throw ROMStorageError.unsupportedFileType(ext.isEmpty ? "unknown" : ext)
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        guard size > 0 else { throw ROMStorageError.emptyFile }
        guard size <= maxROMSize else { throw ROMStorageError.fileTooLarge }
        guard hasRoom(forBytes: size) else { throw ROMStorageError.notEnoughSpace }

        let header = try NDSHeader.read(from: sourceURL)

        // Case-insensitive on purpose: device storage is case-sensitive, so
        // "Game.NDS" beside "Game.nds" would be two library entries sharing one
        // `.sav`, one save-state folder and one cheat file. A match is the same
        // ROM, kept at its on-disk name; a new file is always stored as `.nds`.
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        guard let existingURL = try matchingROMURL(forBaseName: baseName) else {
            let destinationURL = try romsDirectoryURL().appendingPathComponent(baseName).appendingPathExtension("nds")
            try copyItem(from: sourceURL, to: destinationURL, replaceExisting: false)
            return destinationURL
        }

        let existingSize = ((try? FileManager.default.attributesOfItem(atPath: existingURL.path))?[.size] as? Int64) ?? -1
        let sameGame = existingSize == size && (try? NDSHeader.read(from: existingURL)) == header
        switch replacePolicy {
        case .always:
            break
        case .ifSameGame where sameGame:
            break
        case .never, .ifSameGame:
            throw ROMStorageError.duplicateFile(existingURL.lastPathComponent)
        }
        // Opening a ROM from our own Files folder hands us the library file
        // itself: nothing to copy, nothing to invalidate.
        if sourceURL.standardizedFileURL.resolvingSymlinksInPath() == existingURL.standardizedFileURL.resolvingSymlinksInPath() {
            return existingURL
        }
        let existingBaseName = existingURL.deletingPathExtension().lastPathComponent
        guard !isOpen(baseName: existingBaseName) else {
            throw ROMStorageError.romInUse(existingBaseName)
        }

        try copyItem(from: sourceURL, to: existingURL, replaceExisting: true)
        // A different game under the same name must not inherit the old
        // one's save states: auto-resume would load them into the new ROM and
        // the core would flush their SRAM over the real `.sav`.
        if !sameGame {
            setAsideSaveStates(baseName: existingBaseName)
            keepCopyOfBatterySave(baseName: existingBaseName)
        }
        // The cached icon and thumbnail were rendered from the file just
        // replaced; the cells re-decode from the new one.
        ROMIconStore.invalidate(baseName: existingBaseName)
        ThumbnailManager.invalidate(baseName: existingBaseName)
        return existingURL
    }

    /// Moves `SaveStates/<baseName>/` to `SaveStates/<baseName>.old/`
    /// (`.old2`, `.old3`, ... if that is taken) so nothing is deleted, but
    /// nothing is resumed into a ROM it does not belong to either.
    private static func setAsideSaveStates(baseName: String) {
        let fileManager = FileManager.default
        guard let directory = NDSSaveStatePaths.directory(forBaseName: baseName),
              fileManager.fileExists(atPath: directory.path) else { return }
        var counter = 1
        var target = NDSSaveStatePaths.directory(forBaseName: "\(baseName).old")
        while let candidate = target, fileManager.fileExists(atPath: candidate.path) {
            counter += 1
            target = NDSSaveStatePaths.directory(forBaseName: "\(baseName).old\(counter)")
        }
        guard let target else { return }
        do {
            try fileManager.moveItem(at: directory, to: target)
        } catch {
            debugLog("Could not set aside save states for \(baseName): \(error.localizedDescription)")
        }
    }

    /// The battery save stays in place (a ROM hack of the same game is the
    /// common reason to replace, and it expects to continue that save), but
    /// a different game will reformat it on its first save, so a copy is
    /// kept beside it under the same `.old` naming as the states.
    private static func keepCopyOfBatterySave(baseName: String) {
        let fileManager = FileManager.default
        guard let save = INDSSaveBackup.saveURL(baseName: baseName),
              fileManager.fileExists(atPath: save.path) else { return }
        var counter = 1
        var target = INDSSaveBackup.saveURL(baseName: "\(baseName).old")
        while let candidate = target, fileManager.fileExists(atPath: candidate.path) {
            counter += 1
            target = INDSSaveBackup.saveURL(baseName: "\(baseName).old\(counter)")
        }
        guard let target else { return }
        do {
            try fileManager.copyItem(at: save, to: target)
        } catch {
            debugLog("Could not keep a copy of the battery save for \(baseName): \(error.localizedDescription)")
        }
    }

    /// Imports a `.sav` battery save, matching it to an already-imported ROM
    /// by base filename (case-insensitive). Throws `.noMatchingROM` rather
    /// than silently copying an orphaned save that nothing would ever read.
    @discardableResult
    static func importSave(from sourceURL: URL, replaceExisting: Bool) throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == saveExtension else {
            throw ROMStorageError.unsupportedFileType(ext.isEmpty ? "unknown" : ext)
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        guard size > 0 else { throw ROMStorageError.emptyFile }

        let savBaseName = sourceURL.deletingPathExtension().lastPathComponent
        guard let matchedROMBaseName = try matchingROMBaseName(forSaveBaseName: savBaseName) else {
            throw ROMStorageError.noMatchingROM(savBaseName)
        }

        let destinationURL = try savesDirectoryURL()
            .appendingPathComponent(matchedROMBaseName)
            .appendingPathExtension(saveExtension)
        if FileManager.default.fileExists(atPath: destinationURL.path), !replaceExisting {
            throw ROMStorageError.duplicateFile(destinationURL.lastPathComponent)
        }

        try copyItem(from: sourceURL, to: destinationURL, replaceExisting: replaceExisting)
        return destinationURL
    }

    /// Finds a `.nds` file in the ROMs directory whose base name matches
    /// `saveBaseName` case-insensitively, returning that file's *exact*
    /// on-disk base name (so the copied `.sav` lines up byte-for-byte with
    /// what `MelonDSCoreBridge` derives from the real ROM filename).
    private static func matchingROMBaseName(forSaveBaseName saveBaseName: String) throws -> String? {
        try matchingROMURL(forBaseName: saveBaseName)?.deletingPathExtension().lastPathComponent
    }

    /// The on-disk `.nds` (any extension case) whose base name equals
    /// `baseName` case-insensitively, if there is one.
    private static func matchingROMURL(forBaseName baseName: String) throws -> URL? {
        let directory = try romsDirectoryURL()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return urls.first { url in
            url.pathExtension.lowercased() == "nds"
                && url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
        }
    }

    /// Extracts every `.nds`/`.sav` entry from `sourceURL` (a `.zip` or
    /// `.7z` archive — `extract` is `NDSZipExtractor.extractEntries` or
    /// `NDS7zExtractor.extractEntries`, whichever matches `sourceURL`'s
    /// extension) into a scratch directory, imports the ROMs first, then
    /// the saves (so a save bundled alongside its ROM in the same archive
    /// can match it), and reports any per-entry failures instead of
    /// aborting the whole batch. Both archive formats share this exact
    /// success/duplicate/error flow — only the extraction step differs.
    private static func importROMsFromArchive(
        at sourceURL: URL,
        replacePolicy: ROMReplacePolicy,
        extract: (_ archiveURL: URL, _ extensions: Set<String>, _ directory: URL) -> [URL]
    ) throws -> ROMImportResult {
        let fileManager = FileManager.default
        let tmpDir = fileManager.temporaryDirectory.appendingPathComponent("\(importTempPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tmpDir) }

        // The whole extraction lands in tmp BEFORE importROM applies its own
        // per-entry guard, and it is the phase that eats the most disk. The
        // compressed size is a lower bound on what comes out: if even that
        // does not fit, a localized error now beats filling the disk halfway.
        // Note: knowingly a lower bound — an archive that expands to much
        // more can still fill tmp and will fail with the extractor's raw
        // error, exactly as before.
        // A picker/"Open in eDuo" URL is unreadable outside its security
        // scope: without opening it here the stat fails and 0 always "fits".
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        let archiveSize = ((try? fileManager.attributesOfItem(atPath: sourceURL.path))?[.size] as? Int64) ?? 0
        if didStartAccess {
            sourceURL.stopAccessingSecurityScopedResource()
        }
        guard hasRoom(forBytes: archiveSize) else { throw ROMStorageError.notEnoughSpace }

        let extracted = extract(sourceURL, zipROMExtensions.union(zipSaveExtensions), tmpDir)
        guard !extracted.isEmpty else {
            throw ROMStorageError.zipContainsNoSupportedFiles
        }

        var result = ROMImportResult()
        let romEntries = extracted.filter { zipROMExtensions.contains($0.pathExtension.lowercased()) }
        let saveEntries = extracted.filter { zipSaveExtensions.contains($0.pathExtension.lowercased()) }

        for romURL in romEntries {
            do {
                result.importedROMURLs.append(try importROM(from: romURL, replacePolicy: replacePolicy))
            } catch {
                result.failureMessages.append(error.localizedDescription)
            }
        }
        for saveURL in saveEntries {
            do {
                result.importedSaveURLs.append(try importSave(from: saveURL, replaceExisting: replacePolicy == .always))
            } catch {
                result.failureMessages.append(error.localizedDescription)
            }
        }
        return result
    }

    /// Removes `ROMImport-*` scratch directories an earlier import left in
    /// tmp because it never reached its own cleanup (a crash or memory kill
    /// mid-extraction). Called once at launch, before any import can start.
    static func removeStaleImportDirectories() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(importTempPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Delete

    /// Deletes the ROM file itself, its cheat list, cached icon and thumbnail,
    /// and — when `alsoDeleteSaveData` is true — its battery save, save
    /// states and per-game settings too, plus the per-ROM UserDefaults
    /// entries (favorite/play time/last played), so nothing orphaned survives
    /// under this base name.
    static func deleteROM(_ rom: ROMFile, alsoDeleteSaveData: Bool) throws {
        guard !isOpen(baseName: rom.baseName) else {
            throw ROMStorageError.romInUse(rom.baseName)
        }
        try FileManager.default.removeItem(at: rom.fileURL)
        // The icon and thumbnail belong to the file, not the name: a later
        // import under this filename must render its own.
        ROMIconStore.invalidate(baseName: rom.baseName)
        ThumbnailManager.invalidate(baseName: rom.baseName)
        // Cheats go with the ROM either way. Action Replay codes poke fixed
        // addresses, so a different game imported later under this name
        // would boot with them applied to the wrong memory.
        if let cheatsURL = NDSCheatFileStore.fileURL(forBaseName: rom.baseName) {
            try? FileManager.default.removeItem(at: cheatsURL)
        }
        guard alsoDeleteSaveData else { return }

        if let saveURL = rom.saveFileURL {
            try? FileManager.default.removeItem(at: saveURL)
        }
        // The `.sav.bak` safety net too: left behind, a later ROM imported
        // under this name would be offered "Recover Cartridge Save" with
        // *this* game's SRAM.
        if let backupURL = INDSSaveBackup.backupURL(baseName: rom.baseName) {
            try? FileManager.default.removeItem(at: backupURL)
        }
        NDSSaveStatePaths.delete(baseName: rom.baseName)
        INDSPerGameProfileStore.remove(forGame: rom.baseName)

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "\(rom.filename)_isFavorite")
        defaults.removeObject(forKey: "\(rom.filename)_playTime")
        defaults.removeObject(forKey: "\(rom.filename)_lastPlayed")
    }

    // MARK: - Rename

    /// Renames the ROM file and every companion file/UserDefaults entry keyed
    /// by its base name, so a rename never orphans save data or resets
    /// favorite/play-time/last-played history. Returns the ROM's new URL.
    @discardableResult
    static func renameROM(_ rom: ROMFile, toBaseName rawNewBaseName: String) throws -> URL {
        let newBaseName = rawNewBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 240 bytes leaves room for the longest companion suffix (`.sav.bak`)
        // under APFS's 255-byte name limit, so no derived file can ever fail
        // to be written for a name the ROM itself accepted.
        // No leading dot: `listROMs` skips hidden files, so ".Game.nds" would
        // vanish from the library together with its save and states.
        guard !newBaseName.isEmpty, !newBaseName.hasPrefix("."),
              !newBaseName.contains("/"), !newBaseName.contains(":"),
              newBaseName.utf8.count <= 240 else {
            throw ROMStorageError.invalidName
        }
        guard newBaseName != rom.baseName else {
            return rom.fileURL
        }
        guard !isOpen(baseName: rom.baseName) else {
            throw ROMStorageError.romInUse(rom.baseName)
        }

        let newFilename = (newBaseName as NSString).appendingPathExtension("nds") ?? "\(newBaseName).nds"
        let newROMURL = try romsDirectoryURL().appendingPathComponent(newFilename)
        if FileManager.default.fileExists(atPath: newROMURL.path) {
            throw ROMStorageError.duplicateFile(newFilename)
        }
        // Another ROM whose name differs only in case would share this one's
        // `.sav`, states and cheats on case-sensitive device storage.
        if let other = try matchingROMURL(forBaseName: newBaseName),
           other.standardizedFileURL.path != rom.fileURL.standardizedFileURL.path {
            throw ROMStorageError.duplicateFile(other.lastPathComponent)
        }
        // Save data already under the target name is a "Delete ROM Only"
        // leftover, kept on purpose for a re-import — refuse rather than
        // silently wipe it.
        let newSaveURL = try savesDirectoryURL().appendingPathComponent(newBaseName).appendingPathExtension("sav")
        if FileManager.default.fileExists(atPath: newSaveURL.path) {
            throw ROMStorageError.duplicateFile(newSaveURL.lastPathComponent)
        }
        if NDSSaveStatePaths.hasAnySaveState(baseName: newBaseName) {
            throw ROMStorageError.duplicateFile(newBaseName)
        }

        // The battery save moves first and for real: a rename that silently
        // left the `.sav` behind under the old name would look like lost
        // progress. If the ROM move then fails, put the save back.
        let oldSaveURL = rom.saveFileURL
        let hasSave = oldSaveURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if hasSave, let oldSaveURL {
            try FileManager.default.moveItem(at: oldSaveURL, to: newSaveURL)
        }
        do {
            try FileManager.default.moveItem(at: rom.fileURL, to: newROMURL)
        } catch {
            if hasSave, let oldSaveURL {
                try? FileManager.default.moveItem(at: newSaveURL, to: oldSaveURL)
            }
            throw error
        }

        if let oldBackup = INDSSaveBackup.backupURL(baseName: rom.baseName),
           let newBackup = INDSSaveBackup.backupURL(baseName: newBaseName),
           FileManager.default.fileExists(atPath: oldBackup.path) {
            try? FileManager.default.removeItem(at: newBackup)
            try? FileManager.default.moveItem(at: oldBackup, to: newBackup)
        }
        NDSSaveStatePaths.rename(fromBaseName: rom.baseName, toBaseName: newBaseName)
        ROMIconStore.rename(fromBaseName: rom.baseName, toBaseName: newBaseName)
        ThumbnailManager.rename(fromBaseName: rom.baseName, toBaseName: newBaseName)
        if let oldCheats = NDSCheatFileStore.fileURL(forBaseName: rom.baseName),
           let newCheats = NDSCheatFileStore.fileURL(forBaseName: newBaseName),
           FileManager.default.fileExists(atPath: oldCheats.path) {
            try? FileManager.default.removeItem(at: newCheats)
            try? FileManager.default.moveItem(at: oldCheats, to: newCheats)
        }
        INDSPerGameProfileStore.rename(fromGame: rom.baseName, toGame: newBaseName)

        let defaults = UserDefaults.standard
        let oldFilename = rom.filename
        for suffix in ["_isFavorite", "_playTime", "_lastPlayed"] {
            let oldKey = "\(oldFilename)\(suffix)"
            let newKey = "\(newFilename)\(suffix)"
            if let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
                defaults.removeObject(forKey: oldKey)
            }
        }

        return newROMURL
    }

    static func copyItem(from sourceURL: URL, to destinationURL: URL, replaceExisting: Bool) throws {
        let fileManager = FileManager.default
        // Opening a file from our own Files folder ("On My iPhone/eDuo/ROMs")
        // hands us source == destination (with a /private prefix). Removing
        // the destination first would delete the only copy — nothing to do.
        if sourceURL.standardizedFileURL.resolvingSymlinksInPath() == destinationURL.standardizedFileURL.resolvingSymlinksInPath() {
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard replaceExisting else {
                throw ROMStorageError.duplicateFile(destinationURL.lastPathComponent)
            }
            // Copy beside the target and swap, never remove-then-copy: a copy
            // that dies half-way (disk full, provider hiccup) must not leave
            // the user with neither file — this is the "Replace?" path for
            // battery saves. Dotfile so `listROMs` never lists the staging copy.
            let staging = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).importing")
            try? fileManager.removeItem(at: staging)
            do {
                try fileManager.copyItem(at: sourceURL, to: staging)
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: staging)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
            return
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func directoryURL(named name: String) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ROMStorageError.unavailableDocumentsDirectory
        }
        let directory = documents.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
