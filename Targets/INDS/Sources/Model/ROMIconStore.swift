import UIKit

/// Caches rendered NDS banner icons as PNGs in `Documents/Icons/<baseName>.png`
/// so `NDSBanner.renderIcon()` (bitmap decode + CGImage build) only runs once
/// per ROM. Mirrors iGBA's `ScreenshotManager` caching shape, scoped to just
/// what the icon needs (banner icons are tiny — 32x32 — so no dedicated
/// PNG-encoding thread is needed the way iGBA's full-screen screenshots do).
/// 3DS games (and .3dsx homebrew) get the 48x48 icon of their SMDH, read by
/// the core's loader and cached in the same folder.
enum ROMIconStore {
    private static let directoryName = "Icons"
    /// Memory entry: the image plus the `ROMFile.contentKey` it was made for,
    /// so a file replaced behind our back (Files app) is not served stale.
    private final class Entry {
        let image: UIImage
        let contentKey: String
        init(_ image: UIImage, _ contentKey: String) {
            self.image = image
            self.contentKey = contentKey
        }
    }
    private static let memoryCache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 200
        return cache
    }()

    /// `contentKey`s of 3DS files with no SMDH icon (a bare .3dsx): not worth
    /// reopening the file every time a cell appears. In memory only.
    private static var noIconKeys = Set<String>()
    private static let noIconLock = NSLock()
    /// The 3DS loader (key setup, file parsing) is not meant to run from
    /// several threads at once, and a library has many cells loading together.
    private static let threeDSLoaderLock = NSLock()

    private static var directory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func cacheURL(baseName: String) -> URL? {
        directory?.appendingPathComponent(baseName).appendingPathExtension("png")
    }

    /// Returns the ROM's banner icon, preferring the on-disk PNG cache, then
    /// an in-memory cache, and only falling back to parsing+rendering the
    /// banner (and writing the cache) when neither exists yet. Returns `nil`
    /// when the ROM has no parseable banner — callers should show a
    /// placeholder (initials card) in that case.
    static func icon(for rom: ROMFile) -> UIImage? {
        let key = rom.baseName as NSString
        if let cached = memoryCache.object(forKey: key), cached.contentKey == rom.contentKey {
            return cached.image
        }

        // A cover the user chose wins over the banner (and is the only art a
        // 3DS game has). It lives in its own folder, never in the icon cache.
        if let url = coverURL(baseName: rom.baseName), let cover = UIImage(contentsOfFile: url.path) {
            memoryCache.setObject(Entry(cover, rom.contentKey), forKey: key)
            return cover
        }

        if let url = cacheURL(baseName: rom.baseName), FileManager.default.fileExists(atPath: url.path) {
            // A cached PNG is only trusted if it is a real picture made for this
            // kind of game: a 3DS game's art is the 48x48 SMDH icon (a 32x32 one
            // came from some other file under this name), and nothing blank or
            // single-colour (a white square once showed up instead of the
            // initials card). Anything else is deleted and rebuilt below.
            if !isStale(cacheURL: url, rom: rom),
               let image = UIImage(contentsOfFile: url.path),
               !isBlank(image),
               !rom.isThreeDS || pixelSize(of: image) == CGSize(width: 48, height: 48) {
                memoryCache.setObject(Entry(image, rom.contentKey), forKey: key)
                return image
            }
            try? FileManager.default.removeItem(at: url)
        }

        let rendered: UIImage?
        if rom.isThreeDS {
            noIconLock.lock()
            let known = noIconKeys.contains(rom.contentKey)
            noIconLock.unlock()
            if known { return nil }
            rendered = renderThreeDSIcon(path: rom.fileURL.path)
            if rendered == nil || isBlank(rendered!) {
                noIconLock.lock()
                noIconKeys.insert(rom.contentKey)
                noIconLock.unlock()
            }
        } else {
            rendered = rom.banner?.renderIcon()
        }
        // Never cache (or show) an empty icon: the initials card is better art.
        guard let rendered, !isBlank(rendered) else { return nil }
        memoryCache.setObject(Entry(rendered, rom.contentKey), forKey: key)
        if let url = cacheURL(baseName: rom.baseName), let data = rendered.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        return rendered
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// True for an icon that carries no picture: fully transparent, or every
    /// visible pixel the same colour (an all-white SMDH, a blank banner).
    static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0, cg.width * cg.height <= 256 * 256 else {
            return false
        }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        var first: ArraySlice<UInt8>?
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] != 0 {
            let px = rgba[i..<(i + 4)]
            if let first { if px != first { return false } } else { first = px }
        }
        return true  // no visible pixel at all, or all the same
    }

    /// A cached PNG older than the ROM file was made from a previous version
    /// of it (replaced from the Files app without going through the importer,
    /// which invalidates explicitly).
    private static func isStale(cacheURL: URL, rom: ROMFile) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let cached = (try? cacheURL.resourceValues(forKeys: keys))?.contentModificationDate,
              let source = (try? rom.fileURL.resourceValues(forKeys: keys))?.contentModificationDate else {
            return false
        }
        return source > cached
    }

    /// The SMDH icon of a 3DS game or .3dsx (48x48 RGB565 → RGBA8, from the
    /// core's loader — `E3DSCopyIcon`). `nil` when the file carries none.
    /// Opaque pixels, scale 1: drawn with `.interpolation(.none)` like the DS
    /// banner so the pixel art stays crisp when the cell scales it up.
    private static func renderThreeDSIcon(path: String) -> UIImage? {
        var width: Int32 = 0
        var height: Int32 = 0
        threeDSLoaderLock.lock()
        let pixels = E3DSCopyIcon(path, &width, &height)
        threeDSLoaderLock.unlock()
        guard let pixels, width > 0, height > 0 else { return nil }
        defer { free(pixels) }
        let w = Int(width), h = Int(height)
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: w * h * 4) as CFData),
              let cgImage = CGImage(
                width: w,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    // MARK: - Custom covers

    /// `Documents/Covers/<baseName>.png|jpg`: the picture the user picked for a
    /// game ("Change Cover…"), downscaled to `maxCoverSide`. Unlike the icon
    /// cache it is user data, so a "Replace" import keeps it; a rename moves
    /// it and deleting the ROM removes it.
    static let maxCoverSide: CGFloat = 512
    private static let coverExtensions = ["png", "jpg"]

    private static var coversDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Covers", isDirectory: true)
    }

    static func coverURL(baseName: String) -> URL? {
        guard let dir = coversDirectory else { return nil }
        return coverExtensions
            .map { dir.appendingPathComponent(baseName).appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Changes whenever the cover does (empty = none): part of `ROMFile`, so a
    /// reload after Change/Reset repaints every cell that shows the game.
    static func coverStamp(baseName: String) -> String {
        guard let url = coverURL(baseName: baseName) else { return "" }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(date?.timeIntervalSince1970 ?? 1)"
    }

    /// Stores `data` (PNG or JPEG as chosen; anything else, e.g. HEIC, becomes
    /// JPEG) as the cover, shrunk so its longest side is at most 512 px.
    static func setCover(data: Data, baseName: String) throws {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              let dir = coversDirectory else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let scale = min(1, maxCoverSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let encoded = isPNG ? resized.pngData() : resized.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        removeCover(baseName: baseName)
        try encoded.write(to: dir.appendingPathComponent(baseName).appendingPathExtension(isPNG ? "png" : "jpg"), options: .atomic)
    }

    static func removeCover(baseName: String) {
        memoryCache.removeObject(forKey: baseName as NSString)
        if let url = coverURL(baseName: baseName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func renameCover(fromBaseName oldName: String, toBaseName newName: String) {
        guard let oldURL = coverURL(baseName: oldName), let dir = coversDirectory else { return }
        removeCover(baseName: newName)
        try? FileManager.default.moveItem(
            at: oldURL,
            to: dir.appendingPathComponent(newName).appendingPathExtension(oldURL.pathExtension))
    }

    /// Removes the cached icon for a ROM (called when a ROM is renamed or
    /// deleted so a stale icon can't survive under the old/reused base name).
    static func invalidate(baseName: String) {
        memoryCache.removeObject(forKey: baseName as NSString)
        if let url = cacheURL(baseName: baseName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Moves a cached icon to a new base name (used by rename) instead of
    /// discarding it, so a rename doesn't force a re-render.
    static func rename(fromBaseName oldName: String, toBaseName newName: String) {
        memoryCache.removeObject(forKey: oldName as NSString)
        memoryCache.removeObject(forKey: newName as NSString)
        renameCover(fromBaseName: oldName, toBaseName: newName)
        guard let oldURL = cacheURL(baseName: oldName), let newURL = cacheURL(baseName: newName),
              FileManager.default.fileExists(atPath: oldURL.path) else { return }
        try? FileManager.default.removeItem(at: newURL)
        try? FileManager.default.moveItem(at: oldURL, to: newURL)
    }
}
