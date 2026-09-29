//
//  INDSControllerLayoutManager.swift
//  eDuo
//
//  Ported and adapted from iGBA's ControllerLayoutManager.swift.
//  Persists the active on-screen controller layout to disk (JSON in
//  Application Support). Own storage directory and notification name so this
//  never collides with iGBA's identically-shaped manager if the two ever end
//  up embedded together.
//

import Foundation

/// Manages persistence of the custom controller layout to disk.
public final class INDSControllerLayoutManager {

    public static let shared = INDSControllerLayoutManager()

    public static let layoutDidChangeNotification = Notification.Name("INDSControllerLayoutDidChange")

    private let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("INDSControllerLayouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var activeLayoutURL: URL {
        storageDirectory.appendingPathComponent("active_layout.json")
    }

    /// Schema version of the persisted file. Bumped when the *defaults* change
    /// shape in a way that makes an older saved layout wrong rather than
    /// merely stale, in which case the old file is discarded instead of
    /// healed. v1 authored positions against a content rect with no reserved
    /// control band, so its d-pad sat on top of L/R (and on the touch screen)
    /// on every device — nothing worth preserving. v2 predates Menu/Layout
    /// being layout entries, so keeping one would leave both backfilled
    /// hidden: no pause button on screen at all. v3 shipped Fast Forward at a
    /// default position below the control band, where `clampedFrame` pushed it
    /// back inside and straight on top of Menu — a layout saved from a build
    /// with that defect would keep the overlap forever, so it goes too.
    private static let currentVersion = 4

    private struct StoredLayout: Codable {
        var version: Int
        var layout: INDSCustomControllerLayout
    }

    private var didLoad = false
    private var _persisted: INDSCustomControllerLayout?
    /// Serial: reads and the write-back both go through it, so a save
    /// immediately followed by a read can't observe the old value.
    private let queue = DispatchQueue(label: "com.mls.inds.controllerlayout")

    private init() {}

    /// The user's saved layout, or `nil` when they have never customized one.
    /// `nil` is meaningful: callers with real geometry (`NDSControllerView`)
    /// build defaults for the exact content rect they are about to lay out
    /// in, which is what keeps the control band pixel-correct per device.
    public var persistedLayout: INDSCustomControllerLayout? {
        queue.sync {
            if !didLoad {
                didLoad = true
                _persisted = loadFromDisk(url: activeLayoutURL)
            }
            return _persisted
        }
    }

    /// Convenience for callers without geometry (the layout editor): the
    /// saved layout if there is one, otherwise defaults built against a
    /// reference content rect. Main-thread only — resolving those defaults
    /// reads the key window's safe-area insets.
    public var activeLayout: INDSCustomControllerLayout {
        get {
            guard let stored = persistedLayout else { return .defaultLayout() }
            let (healedLayout, changed) = stored.healed()
            if changed { persist(healedLayout) }
            return healedLayout
        }
        set { persist(newValue) }
    }

    private func persist(_ layout: INDSCustomControllerLayout) {
        queue.async { [weak self] in
            guard let self else { return }
            self.didLoad = true
            self._persisted = layout
            self.saveToDisk(layout: layout, url: self.activeLayoutURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: layout)
            }
        }
    }

    /// Drops the saved layout so every surface falls back to the defaults
    /// computed for its own geometry, rather than freezing today's defaults
    /// into a file authored against whatever container happened to be around.
    public func resetToDefault() {
        queue.async { [weak self] in
            guard let self else { return }
            self.didLoad = true
            self._persisted = nil
            try? FileManager.default.removeItem(at: self.activeLayoutURL)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: nil)
            }
        }
    }

    // MARK: - Disk I/O

    private func saveToDisk(layout: INDSCustomControllerLayout, url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(StoredLayout(version: Self.currentVersion, layout: layout))
            try data.write(to: url, options: .atomic)
        } catch {
            debugLog("[INDSControllerLayoutManager] Save failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk(url: URL) -> INDSCustomControllerLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) else {
            // Either a v1 file (no `version` key at all) or corrupt — both
            // resolve the same way: forget it and use today's defaults.
            debugLog("[INDSControllerLayoutManager] Discarding pre-v\(Self.currentVersion) layout")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard stored.version >= Self.currentVersion else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return stored.layout
    }
}
