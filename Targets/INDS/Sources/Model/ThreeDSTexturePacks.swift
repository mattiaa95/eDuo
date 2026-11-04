import Foundation

/// Texture packs and texture dumping for 3DS games. The DS core (melonDS) has no texture
/// replacement, so none of this exists for DS.
///
/// Both folders live in `Documents/System` (Files › eDuo › System), keyed by the game's
/// program ID (16 hex digits, `ThreeDSSaveTransfer.programID`):
///
///     load/textures/<ID>/    packs the player drops in; the core replaces matching textures
///     dump/textures/<ID>/    what "Dump Textures" writes: one PNG per texture + a pack.json
///
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

    private static func folder(_ kind: String, programID: UInt64) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("System/\(kind)/textures/\(idString(programID))", isDirectory: true)
    }

    static func packFolder(programID: UInt64) -> URL? { folder("load", programID: programID) }
    static func dumpFolder(programID: UInt64) -> URL? { folder("dump", programID: programID) }

    static func hasDumpedTextures(programID: UInt64) -> Bool {
        guard let url = dumpFolder(programID: programID) else { return false }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasSuffix(".png") }
    }

    /// Where the Files app can be sent: the folder, created if it is not there yet.
    static func filesURL(for folder: URL, create: Bool) -> URL? {
        if create { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return URL(string: folder.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://"))
    }
}
