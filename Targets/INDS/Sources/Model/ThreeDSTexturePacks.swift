import Foundation

/// Texture packs and texture dumping for 3DS games. The DS core (melonDS) has no texture
/// replacement, so none of this exists for DS.
///
/// One folder per game, in `Documents/System` (Files › eDuo › System), keyed by the game's
/// program ID (16 hex digits, `ThreeDSSaveTransfer.programID`), the way PPSSPP does it:
///
///     load/textures/<ID>/    the pack the core replaces textures from AND where "Dump Textures"
///                            writes (PNGs + a pack.json), so nothing is ever copied between
///                            folders: dumps accumulate there across sessions and what the
///                            player edits in it loads at the next start
///
/// Build 68 dumped into `dump/textures/<ID>/`; `migrateLegacyDump` moves that over.
/// "Dump Textures" is remembered per game (UserDefaults `eDuo3DSDumpTextures`, the IDs with
/// it on) and handed to the core before each boot (`E3DSSetDumpTextures`, read at E3DSRun).
enum ThreeDSTexturePacks {
    private static let dumpKey = "eDuo3DSDumpTextures"

    /// 3DS games with a program ID of their own; .3dsx homebrew has none.
    static func supports(_ rom: ROMFile) -> Bool {
        rom.isThreeDS && ThreeDSSaveTransfer.programID(for: rom) != nil
    }

    static func idString(_ programID: UInt64) -> String { String(format: "%016llX", programID) }

    static func isDumping(programID: UInt64) -> Bool {
        (UserDefaults.standard.stringArray(forKey: dumpKey) ?? []).contains(idString(programID))
    }

    static func setDumping(_ on: Bool, programID: UInt64) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: dumpKey) ?? [])
        if on { ids.insert(idString(programID)) } else { ids.remove(idString(programID)) }
        UserDefaults.standard.set(ids.sorted(), forKey: dumpKey)
    }

    /// Call before every `E3DSRun`: off unless this game asked for it.
    static func applyDumpSetting(for rom: ROMFile) {
        let on = ThreeDSSaveTransfer.programID(for: rom).map { isDumping(programID: $0) } ?? false
        E3DSSetDumpTextures(on)
    }

    /// The game's one texture folder (packs and dumps).
    static func packFolder(programID: UInt64) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("System/load/textures/\(idString(programID))", isDirectory: true)
    }

    /// Moves a build 68 dump into the pack folder (the core does the same at every boot).
    static func migrateLegacyDump(programID: UInt64) {
        guard !E3DSIsRunning() else { return }
        _ = E3DSMigrateTextureDump(programID)
    }

    /// Where the Files app can be sent: the folder, created if it is not there yet.
    static func filesURL(for folder: URL, create: Bool) -> URL? {
        if create { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return URL(string: folder.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://"))
    }
}
