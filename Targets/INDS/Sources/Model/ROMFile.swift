import Foundation

struct ROMFile: Identifiable, Equatable {
    let id: String
    let filename: String
    let fileURL: URL
    let creationDate: Date
    let header: NDSHeader?
    /// Parsed icon/title banner (killer-feature game icon + official title).
    /// `nil` for ROMs with no valid banner (some homebrew/hacks) — callers
    /// fall back to `header.title` / the filename and an initials placeholder.
    let banner: NDSBanner?
    /// Size on disk, read once at init: the Size sort compares it twice per
    /// comparison, and a stat per compare on the main thread is what made
    /// that sort stutter on a large library.
    let fileSize: Int64?
    /// `path|mtime|size` — changes when the file behind this name is
    /// replaced, so caches keyed by name (parsed header/banner, the icon a
    /// cell already shows) know to re-read.
    let contentKey: String

    /// Placeholder shown when the header carries no game code.
    static let unknownGameCode = "----"

    /// Filename without its extension — the shared key used to keep every
    /// per-ROM companion file (`.sav`, save states, cached icon, thumbnail)
    /// and UserDefaults entry in sync with the ROM itself.
    var baseName: String { (filename as NSString).deletingPathExtension }

    /// Prefers the banner's official English title (flattened to one line)
    /// over the coarse 12-character ASCII title in the plain header, and
    /// finally the filename — matching `NDSHeader.title`'s own fallback chain.
    var displayName: String {
        if let bannerTitle = banner?.displayTitle, !bannerTitle.isEmpty {
            return bannerTitle
        }
        if let title = header?.title, !title.isEmpty {
            return title
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    /// Runs on the Azahar core (ThreeDSGameViewController) instead of melonDS.
    var isThreeDS: Bool { ROMStorageManager.threeDSExtensions.contains(fileURL.pathExtension.lowercased()) }

    var gameCode: String {
        header?.gameCode.isEmpty == false ? header?.gameCode ?? Self.unknownGameCode : Self.unknownGameCode
    }

    /// Battery save file for this ROM, if `MelonDSCoreBridge` has ever
    /// written one (`Documents/Saves/<baseName>.sav` — see `loadROMAtPath:`
    /// in MelonDSCoreBridge.mm) or the user imported one.
    var saveFileURL: URL? {
        try? ROMStorageManager.savesDirectoryURL().appendingPathComponent(baseName).appendingPathExtension("sav")
    }

    var hasSaveFile: Bool {
        guard let url = saveFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var hasAnySaveState: Bool {
        NDSSaveStatePaths.hasAnySaveState(baseName: baseName)
    }

    var isFavorite: Bool {
        get { UserDefaults.standard.bool(forKey: "\(filename)_isFavorite") }
        set { UserDefaults.standard.set(newValue, forKey: "\(filename)_isFavorite") }
    }

    var playTime: TimeInterval {
        get { UserDefaults.standard.double(forKey: "\(filename)_playTime") }
        set { UserDefaults.standard.set(newValue, forKey: "\(filename)_playTime") }
    }

    var lastPlayedDate: Date? {
        get { UserDefaults.standard.object(forKey: "\(filename)_lastPlayed") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "\(filename)_lastPlayed") }
    }

    var formattedFileSize: String {
        guard let fileSize else { return "-" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// "2 h 15 min", "0 min" — localized by the system, like iGBA. "00:00"
    /// read as a clock, and the grid fell back to the header's game code,
    /// which is "####" on every homebrew.
    var formattedPlayTime: String {
        Self.playTimeFormatter.string(from: TimeInterval(Int(playTime) / 60 * 60)) ?? ""
    }

    private static let playTimeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropLeading
        return f
    }()

    /// Header + banner parsed once per (path, mtime, size). `reload()` runs
    /// on the main thread after every import/delete/rename/pull-to-refresh
    /// and used to reopen every ROM twice each time — linear in library
    /// size. mtime+size in the key so a replaced ROM (same name, new file)
    /// is re-parsed. Unbounded, but it's ~3 KB per ROM.
    private static var parsedCache: [String: (NDSHeader?, NDSBanner?)] = [:]
    private static let parsedCacheLock = NSLock()

    init(fileURL: URL, creationDate: Date) {
        self.id = fileURL.lastPathComponent
        self.filename = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.creationDate = creationDate

        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(fileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        self.fileSize = values?.fileSize.map(Int64.init)
        self.contentKey = key
        Self.parsedCacheLock.lock()
        let cached = Self.parsedCache[key]
        Self.parsedCacheLock.unlock()
        if let cached {
            (self.header, self.banner) = cached
        } else {
            let isDS = fileURL.pathExtension.lowercased() == "nds"
            self.header = isDS ? try? NDSHeader.read(from: fileURL) : nil
            self.banner = isDS ? try? NDSBanner.read(from: fileURL) : nil
            Self.parsedCacheLock.lock()
            Self.parsedCache[key] = (header, banner)
            Self.parsedCacheLock.unlock()
        }
    }

    func recordingPlayStart() {
        UserDefaults.standard.set(Date(), forKey: "\(filename)_lastPlayed")
    }

    func incrementPlayTime(by seconds: TimeInterval) {
        UserDefaults.standard.set(playTime + seconds, forKey: "\(filename)_playTime")
    }
}
