//
//  INDSBackgroundSkinStore.swift
//  eDuo
//
//  Custom background images for the emulation screen, one per orientation.
//  Ported from iGBA's "controller skin" (`SettingsView.backgroundImagePicker`
//  + `setVCBGColor` in EmuVC.mm): same idea and the same on-disk storage
//  decision — the images live in Application Support, never in UserDefaults,
//  which caps out around 4MB and would happily swallow a 12MP photo until it
//  didn't.
//
//  Differences from iGBA, both deliberate:
//    * imports are downsampled to `maxDimension` first. iGBA stores whatever
//      the picker handed it, so a modern camera roll photo means a ~20MB PNG
//      re-decoded on every rotation.
//    * the unlock is PRO-only. iGBA offers "watch an ad instead", but eDuo
//      ships with no ad SDK at all (see docs/LEGAL.md), so there is no ad to
//      watch — the first-48h honeymoon covers "let me try it before I buy".
//

import ImageIO
import UIKit

enum INDSBackgroundSkinOrientation: String, CaseIterable {
    case portrait
    case landscape

    var displayName: String {
        switch self {
        case .portrait:  return NSLocalizedString("Portrait", comment: "Background skin orientation")
        case .landscape: return NSLocalizedString("Landscape", comment: "Background skin orientation")
        }
    }
}

enum INDSBackgroundSkinStore {

    /// Posted after a skin is set or cleared, so a game already on screen can
    /// swap its background without being reopened.
    static let didChangeNotification = Notification.Name("INDSBackgroundSkinDidChange")

    /// Longest edge kept on import. Comfortably above the tallest device in
    /// points at 3x, so the image still looks sharp filling the screen, while
    /// keeping a stored file in the low single-digit MBs.
    private static let maxDimension: CGFloat = 2400

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("INDSBackgroundSkins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(for orientation: INDSBackgroundSkinOrientation) -> URL {
        directory.appendingPathComponent("\(orientation.rawValue).png")
    }

    static func hasSkin(for orientation: INDSBackgroundSkinOrientation) -> Bool {
        FileManager.default.fileExists(atPath: url(for: orientation).path)
    }

    static func image(for orientation: INDSBackgroundSkinOrientation) -> UIImage? {
        UIImage(contentsOfFile: url(for: orientation).path)
    }

    /// Small preview for the Settings row. Goes through ImageIO rather than
    /// `image(for:)` so the full stored PNG is never decoded — that would be
    /// ~10MB of RGBA per orientation held alive by a `@State` for a 62x40
    /// thumbnail.
    static func thumbnail(for orientation: INDSBackgroundSkinOrientation,
                          maxPixel: CGFloat = 240) -> UIImage? {
        let source = CGImageSourceCreateWithURL(url(for: orientation) as CFURL, nil)
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Stores `image` (downsampled) for `orientation`, or clears it when nil.
    @discardableResult
    static func set(_ image: UIImage?, for orientation: INDSBackgroundSkinOrientation) -> Bool {
        let target = url(for: orientation)
        defer {
            // Always on main: the encode below is worth doing off the main
            // thread, but observers of this are UIKit views.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChangeNotification, object: orientation)
            }
        }

        guard let image else {
            try? FileManager.default.removeItem(at: target)
            return true
        }
        guard let data = downsampled(image).pngData() else {
            debugLog("[BackgroundSkin] Could not encode \(orientation.rawValue)")
            return false
        }
        do {
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            debugLog("[BackgroundSkin] Save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Scales down so the longest edge is at most `maxDimension`. Already
    /// small images are returned untouched rather than re-rendered.
    private static func downsampled(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let ratio = maxDimension / longest
        let target = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
