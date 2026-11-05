import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Narrowed by a game screen that pins its orientation (3DS: Screens >
    /// Orientation); everything else leaves it at `.all`.
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Records the install moment the 48h honeymoon is measured from,
        // and starts the transaction listener so offer-code / out-of-band
        // Pro grants activate without the user opening the paywall.
        INDSHoneymoon.recordFirstLaunchIfNeeded()
#if DEBUG
        // Swift has no static initializers like the loopback's C++ self
        // check, so this one is called by hand. It aborts in Debug if the
        // review-prompt thresholds break — the failure it watches for is
        // never asking, which goes unnoticed until the ratings are missing.
        INDSReviewPrompt.selfCheck()
        // On-demand geometry sweep (`-iNDSLayoutSweep`): validates the
        // default layouts against foldable/window sizes no current simulator
        // offers. Without the launch argument it does nothing.
        INDSLayoutSweep.runIfRequested()
        // The same thing, visually (`-iNDSVisualSweep`): renders the
        // emulation screen to PNG at foldable/iPad sizes and exits.
        INDSVisualSweep.runIfRequested()
        // The iPhone Duo's measured geometry (`-iNDSDuoSweep`), driven by
        // `scripts/duo_layout_check.sh`.
        INDSDuoSweep.runIfRequested()
        // Golden images of the Metal DS presentation (`-eDuoMetalGolden`),
        // driven by `scripts/ds_metal_golden_check.sh`.
        DSMetalGoldenHarness.runIfRequested()
        // Drives a 3DS homebrew with synthetic d-pad taps (`-eDuoAutoplay3DS`), for the save checks.
        INDSDebugAutoplay.runIfRequested()
        // The 3DS save container (core test + migration cases, no ROM), `-eDuo3DSSaveSelfTest`.
        INDSSave3DSSelfTest.runIfRequested()
#endif
        EntitlementManager.shared.startTransactionListener()
        EntitlementManager.shared.refreshEntitlementsAsync()

        // Before the first import can start, so it never races a live one.
        ROMStorageManager.removeStaleImportDirectories()

        // A 3DS game's save files are buffered C streams: a game that writes without the
        // flush flag and keeps the file open holds its data in memory, and a swipe-away
        // from the app switcher (or iOS reclaiming a suspended app) never runs our code.
        // Backgrounding is the last moment we do, and the core is already parked then
        // (ThreeDSGameViewController.appWillResignActive), so flush every open stream.
        // Does nothing when no 3DS game runs.
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                if E3DSIsRunning() { fflush(nil) }
            }
        }

        if let url = launchOptions?[.url] as? URL {
            Self.handleFileURL(url)
        }
        return true
    }

    /// Refreshes StoreKit entitlements so offer-code redemptions made while
    /// the app was backgrounded (e.g. in the App Store) activate Pro
    /// automatically on return.
    func applicationWillEnterForeground(_ application: UIApplication) {
        EntitlementManager.shared.refreshEntitlementsAsync()
    }

    /// Routes ONLY the external-display role to our scene delegate (AirPlay
    /// mirroring / HDMI → the TV shows the Top screen, see
    /// INDSExternalDisplayController). Every other role falls through to a
    /// plain configuration so SwiftUI keeps owning the on-device scene.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = INDSExternalSceneDelegate.self
        }
        return configuration
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard url.isFileURL else { return false }
        Self.handleFileURL(url)
        return true
    }

    private static let supportedExternalExtensions: Set<String> = ["nds", "zip", "7z", "gz", "sav"]

    /// Routes a file opened externally ("Open in eDuo" from Files/Safari, or
    /// a plain double-tap on a `.nds`/`.zip`/`.7z`/`.sav`) through the same import
    /// dispatcher the in-app "+" picker uses.
    ///
    /// A duplicate `.nds` is replaced silently only when it is the same game
    /// (`ROMReplacePolicy.ifSameGame`: identical header and size). A different
    /// file under a known name — a hack, a randomizer output — goes through the
    /// same "Already Exists / Replace?" alert the in-app picker uses, and on
    /// confirmation the old save states are set aside rather than resumed into
    /// it. A duplicate `.sav` always asks: it would overwrite the live battery
    /// save, and someone double-tapping a `.sav` in Files to see what it is
    /// must not lose their progress for it.
    @MainActor
    static func handleFileURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard supportedExternalExtensions.contains(ext) else {
            debugLog("Ignoring unsupported external file: \(url.lastPathComponent)")
            return
        }
        // SwiftUI's `onOpenURL` and `application(_:open:)` can both fire for
        // one "Open in eDuo"; two concurrent imports of the same URL would
        // race on the security scope and on the destination file.
        guard inFlight.insert(url).inserted else { return }

        let isSave = (ext == "sav")
        Task.detached(priority: .userInitiated) {
            await importExternal(url, isSave: isSave)
            await MainActor.run { _ = inFlight.remove(url) }
        }
    }

    @MainActor private static var inFlight: Set<URL> = []

    private static func importExternal(_ url: URL, isSave: Bool) async {
        do {
            let outcome = try ROMStorageManager.importAny(from: url, replacePolicy: isSave ? .never : .ifSameGame)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .romImported,
                    object: nil,
                    userInfo: ["filenames": outcome.importedROMURLs.map { $0.lastPathComponent }]
                )
                if !outcome.failureMessages.isEmpty {
                    NotificationCenter.default.post(
                        name: .romImportFailed,
                        object: nil,
                        userInfo: ["message": outcome.failureMessages.joined(separator: "\n")]
                    )
                }
            }
        } catch ROMStorageError.duplicateFile {
            // A `.sav`, or a `.nds` that is not the same game as the one it
            // would replace. Stage a copy in tmp: the security-scoped grant on
            // `url` is tied to this open, and the user's answer can be seconds
            // away.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: staged)
            // `importAny` already closed its own scope; reopen it for the copy.
            let scoped = url.startAccessingSecurityScopedResource()
            let copied = (try? FileManager.default.copyItem(at: url, to: staged)) != nil
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard copied else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .romImportNeedsReplaceConfirm,
                    object: nil,
                    userInfo: ["url": staged]
                )
            }
        } catch {
            debugLog("External ROM import failed: \(error.localizedDescription)")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .romImportFailed,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }
    }
}

#if DEBUG
import Foundation

/// `-eDuoAutoplay3DS` (Debug builds only; inert without the flag): taps the 3DS d-pad on its
/// own so a homebrew game can be driven to the point where it writes its save, for
/// `scripts/save_persistence_check.swift`'s end-to-end runs. The game itself is opened by
/// `-eNDSAutoOpen <name>`. Presses go through the same E3DSSetButton the touch overlay uses.
///
/// 2048 port: random d-pad moves until GAME OVER, then START/A to confirm the initials prompt,
/// which writes sdmc:/3ds/2048-port-3ds/leaderboard.sav.
enum INDSDebugAutoplay {
    /// Live ThreeDSGameViewController instances (init/deinit), for the exit-loop check.
    static let liveGames = NSLock()
    nonisolated(unsafe) static var liveGameCount = 0

    /// `-eDuoAutoplayExitLoop N`: waits for the core, presses START so the game exits by itself
    /// (2048 port: "START to exit"), expects to land back in the library with no alert, reopens
    /// the same game (`-eNDSAutoOpen`) and repeats N times. Logs `[exitloop]` lines.
    static func runExitLoopIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-eDuoAutoplayExitLoop"), i + 1 < args.count,
              let cycles = Int(args[i + 1]) else { return }
        DispatchQueue(label: "eDuo.exitloop").async {
            func alertShown() -> Bool {
                var found = false
                DispatchQueue.main.sync {
                    for scene in UIApplication.shared.connectedScenes {
                        for window in (scene as? UIWindowScene)?.windows ?? [] {
                            var vc = window.rootViewController
                            while let v = vc {
                                if v is UIAlertController { found = true }
                                vc = v.presentedViewController
                            }
                        }
                    }
                }
                return found
            }
            func live() -> Int { liveGames.lock(); defer { liveGames.unlock() }; return liveGameCount }
            func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.25) }
                return cond()
            }
            var passed = 0
            for cycle in 1...cycles {
                guard waitFor(90, { E3DSIsRunning() }) else { NSLog("[exitloop] cycle %d FAIL core never started", cycle); break }
                Thread.sleep(forTimeInterval: 5)
                // Several presses, like the earlier autoplay: the ones after the exit hit a dead core.
                var presses = 0
                while E3DSIsRunning() && presses < 40 {
                    E3DSSetButton(Int32(E3DSButtonStart.rawValue), true)
                    Thread.sleep(forTimeInterval: 0.1)
                    E3DSSetButton(Int32(E3DSButtonStart.rawValue), false)
                    Thread.sleep(forTimeInterval: 0.3)
                    presses += 1
                }
                let ended = !E3DSIsRunning()
                // Keep tapping for a moment after the end: dead-core presses must be harmless.
                for _ in 0..<8 {
                    E3DSSetButton(Int32(E3DSButtonStart.rawValue), true); Thread.sleep(forTimeInterval: 0.05)
                    E3DSSetButton(Int32(E3DSButtonStart.rawValue), false); Thread.sleep(forTimeInterval: 0.05)
                }
                var alert = false
                let landed = waitFor(15, { if alertShown() { alert = true; return true }; return live() == 0 })
                NSLog("[exitloop] cycle %d: presses=%d coreEnded=%d alert=%d landedInLibrary=%d => %@",
                      cycle, presses, ended ? 1 : 0, alert ? 1 : 0, (landed && !alert) ? 1 : 0,
                      (ended && landed && !alert) ? "PASS" : "FAIL")
                guard ended, landed, !alert else { break }
                passed += 1
                if cycle < cycles {
                    Thread.sleep(forTimeInterval: 3)
                    NotificationCenter.default.post(name: .init("eDuoAutoOpenAgain"), object: nil)
                }
            }
            NSLog("[exitloop] done: %d/%d cycles PASS", passed, cycles)
        }
    }

    static func runIfRequested() {
        runExitLoopIfRequested()
        guard ProcessInfo.processInfo.arguments.contains("-eDuoAutoplay3DS") else { return }
        let q = DispatchQueue(label: "eDuo.autoplay")
        q.async {
            // Wait for the core.
            while !E3DSIsRunning() { Thread.sleep(forTimeInterval: 0.5) }
            Thread.sleep(forTimeInterval: 4)
            let dirs = [E3DSButtonUp, E3DSButtonRight, E3DSButtonDown, E3DSButtonLeft]
            let tap = { (b: E3DSButton) in
                E3DSSetButton(Int32(b.rawValue), true)
                Thread.sleep(forTimeInterval: 0.05)
                E3DSSetButton(Int32(b.rawValue), false)
                Thread.sleep(forTimeInterval: 0.07)
            }
            NSLog("[autoplay] moving")
            let end = Date().addingTimeInterval(120)
            while Date() < end && E3DSIsRunning() { tap(dirs.randomElement()!) }
            NSLog("[autoplay] confirming")
            // Initials prompt: change each letter, move on, confirm.
            for i in 0..<3 where E3DSIsRunning() {
                for _ in 0...i { tap(E3DSButtonUp) }
                tap(E3DSButtonRight)
            }
            for _ in 0..<6 where E3DSIsRunning() { tap(E3DSButtonStart); Thread.sleep(forTimeInterval: 0.4); tap(E3DSButtonA); Thread.sleep(forTimeInterval: 0.4) }
            NSLog("[autoplay] done")
            // `-eDuoAutoplaySuspend`: go to the home screen like a swipe-up would (private selector; Debug only).
            if ProcessInfo.processInfo.arguments.contains("-eDuoAutoplaySuspend") {
                Thread.sleep(forTimeInterval: 2)
                DispatchQueue.main.async { UIApplication.shared.perform(NSSelectorFromString("suspend")) }
            }
        }
    }
}

/// `-eDuo3DSSaveSelfTest` (Debug builds only; inert without the flag): checks the 3DS save
/// container end to end without a ROM. (A) the core's own save path against
/// `Saves/eDuoSelfTest.3dssave/` (`E3DSSaveSelfTest`); (B) `ThreeDSSaveTransfer`'s
/// migration from the legacy core folder, the flat layout, folder sharing and a name
/// taken by another game, with fake program IDs. Lines go to the log (`[3dssave]`) and to
/// `Documents/eDuo-3dssave-selftest.txt`, ending in `RESULT PASS n/n` or `RESULT FAIL`.
/// The resulting folders stay in `Documents/Saves` as evidence; every run starts by
/// clearing the previous ones.
enum INDSSave3DSSelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-eDuo3DSSaveSelfTest") else { return }
        DispatchQueue(label: "eDuo.3dssave.selftest").async { run() }
    }

    private static func run() {
        let fm = FileManager.default
        var lines: [String] = []
        var passed = 0, total = 0
        func log(_ line: String) { lines.append(line); NSLog("[3dssave] %@", line) }
        func check(_ ok: Bool, _ what: String) {
            total += 1
            if ok { passed += 1 }
            log("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func finish() {
            let result = passed == total && total > 0 ? "RESULT PASS \(passed)/\(total)" : "RESULT FAIL \(passed)/\(total)"
            log(result)
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? (lines.map { "[3dssave] " + $0 }.joined(separator: "\n") + "\n")
                    .write(to: docs.appendingPathComponent("eDuo-3dssave-selftest.txt"), atomically: true, encoding: .utf8)
            }
        }
        guard !E3DSIsRunning(), let saves = try? ROMStorageManager.savesDirectoryURL() else {
            check(false, "no core running and Saves available")
            return finish()
        }

        // Clean the previous run: test folders, their registry entries, fake legacy folders.
        let prefixes = ["eDuoSelfTest", "eDuoMigration", "eDuoFlat", "eDuoShare"]
        for url in (try? fm.contentsOfDirectory(at: saves, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "3dssave" && prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? fm.removeItem(at: url)
            ThreeDSSaveTransfer.forgetRegistration(ofFolderName: url.deletingPathExtension().lastPathComponent)
        }
        ThreeDSSaveTransfer.forgetRegistration(ofFolderName: "eDuoShareA (00040000000ED604)")
        let pidMigrate: UInt64 = 0x00040000000ED600, pidBoth: UInt64 = 0x00040000000ED601
        let pidFlat: UInt64 = 0x00040000000ED602, pidShare: UInt64 = 0x00040000000ED603
        let pidOther: UInt64 = 0x00040000000ED604, pidKeep: UInt64 = 0x00040000000ED605
        for pid in [pidMigrate, pidBoth, pidFlat, pidShare, pidOther, pidKeep] {
            if let legacy = ThreeDSSaveTransfer.legacySaveFolder(forProgramID: pid) {
                try? fm.removeItem(at: legacy.deletingLastPathComponent())
            }
        }

        // (A) The core's own save path.
        let coreFolder = saves.appendingPathComponent("eDuoSelfTest.3dssave", isDirectory: true)
        var report = [CChar](repeating: 0, count: 4096)
        let rc = E3DSSaveSelfTest(coreFolder.path + "/", &report, 4096)
        let text = report.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        for line in text.split(separator: "\n") { log("core: \(line)") }
        check(rc == 0, "E3DSSaveSelfTest returned \(rc)")

        // (A2) Texture dumping: one folder, pack.json, accumulation, migration, PNG encoder; no ROM.
        var texReport = [CChar](repeating: 0, count: 4096)
        let texRC = E3DSTextureDumpSelfTest(&texReport, 4096)
        let texText = texReport.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        for line in texText.split(separator: "\n") { log("textures: \(line)") }
        check(texRC == 0, "E3DSTextureDumpSelfTest returned \(texRC)")

        // (B) Migration and layout.
        func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
        func put(_ data: Data, _ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        func same(_ url: URL, _ data: Data) -> Bool { (try? Data(contentsOf: url)) == data }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func age(_ folder: URL, days: Double) {
            let past = Date().addingTimeInterval(-days * 86400)
            guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
            for case let url as URL in items {
                try? fm.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
            }
        }
        func legacy(_ pid: UInt64) -> (files: URL, metadata: URL)? {
            guard let files = ThreeDSSaveTransfer.legacySaveFolder(forProgramID: pid) else { return nil }
            return (files, files.deletingLastPathComponent().appendingPathComponent("00000001.metadata"))
        }
        func legacyEmpty(_ pid: UInt64) -> Bool {
            guard let l = legacy(pid) else { return false }
            return !exists(l.files) || ((try? fm.contentsOfDirectory(atPath: l.files.path)) ?? []).isEmpty
        }
        func dir(_ name: String) -> URL { saves.appendingPathComponent("\(name).3dssave", isDirectory: true) }

        // 1. Legacy save, empty container: moved byte-identical, legacy emptied, idempotent.
        do {
            let name = "eDuoMigrationTest", save = bytes(300), inner = bytes(77), meta = bytes(16)
            if let l = legacy(pidMigrate) {
                put(save, l.files.appendingPathComponent("save.bin"))
                put(inner, l.files.appendingPathComponent("sub/inner.dat"))
                put(meta, l.metadata)
            }
            let c = ThreeDSSaveTransfer.container(programID: pidMigrate, baseName: name)
            check(c?.lastPathComponent == "\(name).3dssave", "migrate: container name")
            if let c {
                check(same(c.appendingPathComponent("00000001/save.bin"), save), "migrate: save.bin moved intact")
                check(same(c.appendingPathComponent("00000001/sub/inner.dat"), inner), "migrate: subfolder file moved intact")
                check(same(c.appendingPathComponent("00000001.metadata"), meta), "migrate: metadata moved intact")
            }
            check(legacyEmpty(pidMigrate), "migrate: legacy folder emptied")
            check(legacy(pidMigrate).map { !exists($0.files.deletingLastPathComponent()) } ?? false, "migrate: legacy data folder removed")
            _ = ThreeDSSaveTransfer.container(programID: pidMigrate, baseName: name)
            check(!exists(dir("\(name).old")), "migrate: second run changes nothing")
            check(ThreeDSSaveTransfer.registeredID(forFolderName: name) == "00040000000ED600", "migrate: registered")
        }

        // 2. Both sides have a save, legacy newer: legacy wins, the older container save goes to .old.3dssave.
        do {
            let name = "eDuoMigrationBoth", oldBytes = bytes(120), oldMeta = bytes(16), newBytes = bytes(220), newMeta = bytes(16)
            let c = dir(name)
            put(oldBytes, c.appendingPathComponent("00000001/old.bin"))
            put(oldMeta, c.appendingPathComponent("00000001.metadata"))
            age(c, days: 2)
            if let l = legacy(pidBoth) {
                put(newBytes, l.files.appendingPathComponent("new.bin"))
                put(newMeta, l.metadata)
            }
            let got = ThreeDSSaveTransfer.container(programID: pidBoth, baseName: name)
            check(got == c, "both(legacy newer): container is the existing folder")
            check(same(c.appendingPathComponent("00000001/new.bin"), newBytes), "both(legacy newer): legacy file is live")
            check(!exists(c.appendingPathComponent("00000001/old.bin")), "both(legacy newer): old file gone from container")
            check(same(c.appendingPathComponent("00000001.metadata"), newMeta), "both(legacy newer): legacy metadata is live")
            let old = dir("\(name).old")
            check(same(old.appendingPathComponent("00000001/old.bin"), oldBytes), "both(legacy newer): old save kept in .old.3dssave")
            check(same(old.appendingPathComponent("00000001.metadata"), oldMeta), "both(legacy newer): old metadata kept in .old.3dssave")
            check(legacyEmpty(pidBoth), "both(legacy newer): legacy folder emptied")
        }

        // 3. Both sides have a save, container newer: container stays, legacy kept aside.
        do {
            let name = "eDuoMigrationKeep", liveBytes = bytes(90), liveMeta = bytes(16), oldBytes = bytes(150), oldMeta = bytes(16)
            let c = dir(name)
            put(liveBytes, c.appendingPathComponent("00000001/live.bin"))
            put(liveMeta, c.appendingPathComponent("00000001.metadata"))
            if let l = legacy(pidKeep) {
                put(oldBytes, l.files.appendingPathComponent("legacy.bin"))
                put(oldMeta, l.metadata)
                age(l.files.deletingLastPathComponent(), days: 3)
            }
            _ = ThreeDSSaveTransfer.container(programID: pidKeep, baseName: name)
            check(same(c.appendingPathComponent("00000001/live.bin"), liveBytes), "both(container newer): container save untouched")
            check(!exists(c.appendingPathComponent("00000001/legacy.bin")), "both(container newer): legacy file not mixed in")
            let old = dir("\(name).old")
            check(same(old.appendingPathComponent("00000001/legacy.bin"), oldBytes), "both(container newer): legacy kept in .old.3dssave")
            check(same(old.appendingPathComponent("00000001.metadata"), oldMeta), "both(container newer): legacy metadata kept")
            check(legacyEmpty(pidKeep), "both(container newer): legacy folder emptied")
        }

        // 4. Flat layout (our Export zip): wrapped in 00000001/.
        do {
            let name = "eDuoFlatTest", slot = bytes(64), inner = bytes(33), meta = bytes(16)
            let c = dir(name)
            put(slot, c.appendingPathComponent("slot.bin"))
            put(inner, c.appendingPathComponent("sub/x.dat"))
            put(meta, c.appendingPathComponent("00000001.metadata"))
            _ = ThreeDSSaveTransfer.container(programID: pidFlat, baseName: name)
            check(same(c.appendingPathComponent("00000001/slot.bin"), slot), "flat: file wrapped in 00000001/")
            check(same(c.appendingPathComponent("00000001/sub/x.dat"), inner), "flat: subfolder wrapped in 00000001/")
            check(same(c.appendingPathComponent("00000001.metadata"), meta), "flat: metadata stays beside 00000001/")
            check(!exists(c.appendingPathComponent("slot.bin")) && !exists(c.appendingPathComponent("sub")), "flat: nothing left at the top level")
        }

        // 5. Name resolution: sharing by program ID, and a name taken by another game.
        do {
            let a = "eDuoShareA", b = "eDuoShareB"
            check(ThreeDSSaveTransfer.container(programID: pidShare, baseName: a, prepare: false)?.lastPathComponent == "\(a).3dssave", "resolve: fresh name")
            check(!exists(dir(a)), "resolve: resolving creates nothing")
            put(bytes(8), dir(a).appendingPathComponent("00000001/s.bin"))
            _ = ThreeDSSaveTransfer.container(programID: pidShare, baseName: a)
            check(ThreeDSSaveTransfer.container(programID: pidShare, baseName: b)?.lastPathComponent == "\(a).3dssave", "resolve: second image of the same game shares the first folder")
            let other = ThreeDSSaveTransfer.container(programID: pidOther, baseName: a)?.lastPathComponent
            check(other == "\(a) (00040000000ED604).3dssave", "resolve: name taken by another game gets the ID suffix (\(other ?? "nil"))")
            check(!exists(dir("\(a) (00040000000ED604)")), "resolve: the other game's folder is not created")
        }

        finish()
    }
}
#endif
