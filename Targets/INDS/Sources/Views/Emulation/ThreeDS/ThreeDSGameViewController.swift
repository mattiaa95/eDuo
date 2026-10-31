import AVFoundation
import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The game screen for the second handheld format (Azahar core, Native3DS/E3DS.h).
/// Deliberately small next to `NDSRomViewController`: two Metal layers the
/// core renders into, the same on-screen controller and physical-controller
/// mapping the DS screen uses, and a menu with cheats and save import/export.
/// Rewind and the Duo-specific layouts are DS-only for now.
final class ThreeDSGameViewController: UIViewController {
    private let rom: ROMFile
    private let onQuit: () -> Void

    private let topView = MetalLayerView()
    private let bottomView = MetalLayerView()
    private let controllerView = NDSControllerView()
    private let gamepadManager = INDSGamepadManager()
    private let menuButton = UIButton(type: .system)
    private var stickLink: CADisplayLink?
    private var emulationThread: Thread?
    private var lastStick = CGPoint.zero
    private lazy var programID = E3DSProgramID(rom.fileURL.path)
    /// Picked save files, copied out of the picker's sandbox; they replace
    /// the game's save once the core has stopped (see `emulationEnded`).
    private var pendingSaveImport: URL?
    /// Set when a setting only the next boot picks up (resolution) was changed.
    private var restartAfterStop = false
    /// TestFlight/Debug-only performance overlay (Settings); nil and untouched when off.
    private var perfTimer: Timer?
    private var perfLabel: UILabel?
    /// Paused by the app resigning active (not by the menu): only that case auto-resumes.
    private var pausedByLifecycle = false
    private var pressMerger = INDSPressMerger()
    /// True from picking a slot until the save/load finishes (the slot sheet's
    /// onDisappear must not resume the game meanwhile).
    private var stateOpInFlight = false

    init(rom: ROMFile, onQuit: @escaping () -> Void) {
        self.rom = rom
        self.onQuit = onQuit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        [topView, bottomView].forEach(view.addSubview)

        controllerView.delegate = self
        view.addSubview(controllerView)
        gamepadManager.delegate = self
        // The left stick is the Circle Pad (pollStick); don't also press the D-pad.
        gamepadManager.stickDrivesDPad = { INDSControllerOverlayPreferences.stickAlsoMovesDPad3DS }
        // A controller can already be connected before the delegate is set.
        applyGamepadConnectionState()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(gamepadOverlayPreferenceChanged),
                           name: INDSControllerOverlayPreferences.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(orientationLockChanged),
                           name: INDSOrientationLock.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(batterySaverStateChanged),
                           name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(batterySaverStateChanged),
                           name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)

        menuButton.setImage(UIImage(systemName: "pause.circle.fill"), for: .normal)
        menuButton.tintColor = .white.withAlphaComponent(0.7)
        menuButton.accessibilityLabel = NSLocalizedString("Menu", comment: "HUD button caption: opens the pause menu")
        menuButton.addAction(UIAction { [weak self] _ in self?.showMenu() }, for: .touchUpInside)
        view.addSubview(menuButton)

        let touch = UILongPressGestureRecognizer(target: self, action: #selector(bottomTouched(_:)))
        touch.minimumPressDuration = 0
        bottomView.addGestureRecognizer(touch)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds.inset(by: view.safeAreaInsets)
        let (top, bottom) = Self.screenRects(in: bounds, landscapeStacked: ThreeDSScreenPrefs.landscapeStacked)
        topView.frame = top
        bottomView.frame = bottom
        controllerView.frame = view.bounds
        controllerView.screenLayoutMode = bounds.width > bounds.height ? .sideBySide : .stacked
        menuButton.frame = CGRect(x: bounds.maxX - 44, y: bounds.minY + 4, width: 40, height: 40)
        pushLayers()
        startIfNeeded()
    }

    /// Top screen 5:3, bottom 4:3, both 240 px tall on the console. Portrait:
    /// stacked at the top, controls below. Landscape: side by side at the
    /// largest size that fits (the controls overlay the outer edges, as on
    /// the DS screen), or stacked in the middle column if the player picks it.
    static func screenRects(in bounds: CGRect, landscapeStacked: Bool = false) -> (CGRect, CGRect) {
        if bounds.width > bounds.height, !landscapeStacked {
            let s = min(bounds.width / 720, bounds.height / 240)
            let top = CGRect(x: bounds.midX - 360 * s, y: bounds.midY - 120 * s, width: 400 * s, height: 240 * s)
            return (top, CGRect(x: top.maxX, y: top.minY, width: 320 * s, height: 240 * s))
        }
        if bounds.width > bounds.height {
            let column = min(bounds.width * 0.5, bounds.height * 5 / 3 * 0.55)
            let topH = column * 3 / 5
            let bottomH = min(bounds.height - topH, column * 0.8 * 3 / 4)
            let top = CGRect(x: bounds.midX - column / 2, y: bounds.minY, width: column, height: topH)
            let bottomW = bottomH * 4 / 3
            return (top, CGRect(x: bounds.midX - bottomW / 2, y: top.maxY, width: bottomW, height: bottomH))
        }
        let topH = bounds.width * 3 / 5
        let top = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: topH)
        let bottomW = bounds.width * 0.8
        return (top, CGRect(x: bounds.midX - bottomW / 2, y: top.maxY, width: bottomW, height: bottomW * 3 / 4))
    }

    private func pushLayers() {
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let t = topView.metalLayer, b = bottomView.metalLayer
        t.contentsScale = scale; b.contentsScale = scale
        t.drawableSize = CGSize(width: topView.bounds.width * scale, height: topView.bounds.height * scale)
        b.drawableSize = CGSize(width: bottomView.bounds.width * scale, height: bottomView.bounds.height * scale)
        E3DSSetLayers(Unmanaged.passUnretained(t).toOpaque(), t.drawableSize.width, t.drawableSize.height,
                      Unmanaged.passUnretained(b).toOpaque(), b.drawableSize.width, b.drawableSize.height)
    }

    private func startIfNeeded() {
        guard emulationThread == nil, topView.bounds.width > 0 else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let path = rom.fileURL.path
        E3DSSetResolution(Int32(ThreeDSScreenPrefs.resolution))
        applyDiagnostics()
        batterySaverStateChanged()
        let thread = Thread { [weak self] in
            let result = E3DSRun(path)
            DispatchQueue.main.async { self?.emulationEnded(result: result) }
        }
        thread.name = "eDuo.3DS"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 8 << 20
        emulationThread = thread
        thread.start()

        let link = CADisplayLink(target: self, selector: #selector(pollStick))
        link.add(to: .main, forMode: .common)
        stickLink = link
    }

    /// The physical left stick drives the Circle Pad directly — the DS
    /// mapping only knows a d-pad.
    @objc private func pollStick() {
        guard let stick = GCController.current?.extendedGamepad?.leftThumbstick else { return }
        let p = CGPoint(x: CGFloat(stick.xAxis.value), y: CGFloat(stick.yAxis.value))
        guard p != lastStick else { return }
        lastStick = p
        E3DSSetStick(Int32(E3DSStickCircle.rawValue), Float(p.x), Float(p.y))
    }

    @objc private func bottomTouched(_ gesture: UILongPressGestureRecognizer) {
        let scale = bottomView.metalLayer.contentsScale
        let p = gesture.location(in: bottomView)
        switch gesture.state {
        case .began, .changed: E3DSTouch(true, Float(p.x * scale), Float(p.y * scale))
        default: E3DSTouch(false, 0, 0)
        }
    }

    /// Same rule as the DS screen's speed clamp (Settings > Battery): Low Power
    /// Mode, or a hot device. The core then runs with vsync on and speed capped at 100 %.
    @objc private func batterySaverStateChanged() {
        DispatchQueue.main.async {
            var on = INDSBatterySaverPreferences.respectLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled
            if INDSBatterySaverPreferences.autoThrottleWhenHot {
                switch ProcessInfo.processInfo.thermalState {
                case .serious, .critical: on = true
                default: break
                }
            }
            E3DSSetBatterySaver(on)
        }
    }

    /// Metal work submitted from the background kills the app, so the core
    /// must be parked (no GPU work in flight) before iOS takes the GPU away.
    @objc private func appWillResignActive() {
        guard E3DSIsRunning(), !pausedByLifecycle, presentedViewController == nil else { return }
        pausedByLifecycle = true
        E3DSSetPaused(true)
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "eDuo.3ds.park") {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        }
        _ = E3DSWaitParked(150)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }

    @objc private func appDidBecomeActive() {
        let resume = pausedByLifecycle && presentedViewController == nil
        pausedByLifecycle = false
        if resume { E3DSSetPaused(false) }
    }

    private func showMenu() {
        E3DSSetPaused(true)
        let sheet = UIAlertController(title: rom.displayName, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Resume", comment: ""), style: .cancel) { _ in
            E3DSSetPaused(false)
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Save State", comment: ""), style: .default) { [weak self] _ in
            self?.showStateSlots(.save)
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Load State", comment: ""), style: .default) { [weak self] _ in
            self?.showStateSlots(.load)
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Screens", comment: ""), style: .default) { [weak self] _ in
            self?.showScreenOptions()
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cheats", comment: ""), style: .default) { [weak self] _ in
            self?.showCheats()
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Import Save", comment: "3DS pause menu: replace the game's save with one exported from a console"), style: .default) { [weak self] _ in
            self?.pickSaveToImport()
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Export Save", comment: "3DS pause menu: copy the game's save out to Files"), style: .default) { [weak self] _ in
            self?.exportSave()
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Share Log", comment: "Shares the emulator log file so a tester can send it"), style: .default) { [weak self] _ in
            self?.shareLog(from: self?.menuButton) { E3DSSetPaused(false) }
        })
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Quit to Library", comment: ""), style: .destructive) { [weak self] _ in
            self?.quit()
        })
        sheet.popoverPresentationController?.sourceView = menuButton
        present(sheet, animated: true)
    }

    /// Stats overlay (public, UserDefaults key only) plus TestFlight/Debug-only VSync / unlimited speed A/B.
    /// Defaults change nothing.
    private func applyDiagnostics() {
        perfTimer?.invalidate(); perfTimer = nil
        perfLabel?.removeFromSuperview(); perfLabel = nil
        let defaults = UserDefaults.standard
        if DSPerfProbe.isTestBuild {
            let vsync = defaults.object(forKey: "eDuo3DSVSync") == nil ? -1 : defaults.integer(forKey: "eDuo3DSVSync")
            E3DSSetDiagnostics(Int32(vsync), defaults.bool(forKey: "eDuo3DSUnlimited"))
        }
        guard defaults.bool(forKey: DSPerfProbe.overlayKey) else { E3DSSetStatsEnabled(false); return }
        E3DSSetStatsEnabled(true)
        let label = UILabel()
        label.numberOfLines = 3
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .green
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.isUserInteractionEnabled = false
        label.text = "perf..."
        label.sizeToFit()
        label.frame.origin = CGPoint(x: view.safeAreaInsets.left + 4, y: view.safeAreaInsets.top + 4)
        view.addSubview(label)
        perfLabel = label
        perfTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let label = self.perfLabel else { return }
            var s = E3DSStats()
            guard E3DSSampleStats(&s) else { return }
            let hot = withUnsafePointer(to: &s.hotThread) {
                $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            label.text = String(format: "speed %.0f%%  emu %.0f fps  present %.0f fps\ncore CPU %.0f%%  process %.0f%%\nhot: %@ %.0f%%",
                                s.emulationSpeed, s.gameFPS, s.presentFPS, s.coreCPU, s.processCPU,
                                hot.isEmpty ? "?" : hot, s.hotCPU)
            print("[perf] 3ds", label.text?.replacingOccurrences(of: "\n", with: "  ") ?? "")
            label.sizeToFit()
        }
    }

    private func quit() {
        perfTimer?.invalidate()
        stickLink?.invalidate()
        if E3DSIsRunning() { E3DSStop() } else { onQuit() }
    }

    private func emulationEnded(result: Int32) {
        perfTimer?.invalidate(); perfTimer = nil
        stickLink?.invalidate()
        emulationThread = nil
        if let staged = pendingSaveImport {
            pendingSaveImport = nil
            replaceSave(with: staged)
            startIfNeeded()
            return
        }
        if restartAfterStop {
            restartAfterStop = false
            startIfNeeded()
            return
        }
        guard let message = Self.message(for: result) else { onQuit(); return }
        let alert = UIAlertController(title: rom.displayName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Share Log", comment: "Shares the emulator log file so a tester can send it"), style: .default) { [weak self] _ in
            self?.shareLog(from: self?.view) { self?.onQuit() }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { [weak self] _ in
            self?.onQuit()
        })
        present(alert, animated: true)
    }

    /// The core's own log (patch 0003: Documents/System/log/core_log.txt).
    /// Nothing is sent anywhere: the player picks where it goes, usually Discord.
    static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("System/log/core_log.txt")
    }

    private func shareLog(from source: UIView?, completion: @escaping () -> Void) {
        guard let url = Self.logURL, FileManager.default.fileExists(atPath: url.path) else { completion(); return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = source ?? view
        share.completionWithItemsHandler = { _, _, _, _ in completion() }
        present(share, animated: true)
    }

    // MARK: - Screens

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        INDSOrientationLock.apply(from: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        INDSOrientationLock.apply(from: self) // the scene exists only now
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        INDSOrientationLock.release(from: self)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        INDSOrientationLock.current.mask
    }

    @objc private func orientationLockChanged() {
        guard view.window != nil else { return }
        INDSOrientationLock.apply(from: self)
    }

    private func showScreenOptions() {
        let sheet = UIAlertController(title: NSLocalizedString("Screens", comment: ""), message: nil, preferredStyle: .actionSheet)
        let mark = { (on: Bool, title: String) in on ? "✓ " + title : title }
        for option in INDSOrientationLock.allCases {
            let title = NSLocalizedString("Orientation", comment: "") + ": " + option.title
            sheet.addAction(UIAlertAction(title: mark(INDSOrientationLock.current == option, title), style: .default) { _ in
                // The notification re-applies the lock (orientationLockChanged).
                INDSOrientationLock.current = option
                E3DSSetPaused(false)
            })
        }
        for stacked in [false, true] {
            let title = NSLocalizedString("Landscape", comment: "") + ": "
                + (stacked ? NSLocalizedString("Stacked", comment: "") : NSLocalizedString("Side by Side", comment: ""))
            sheet.addAction(UIAlertAction(title: mark(ThreeDSScreenPrefs.landscapeStacked == stacked, title), style: .default) { [weak self] _ in
                ThreeDSScreenPrefs.landscapeStacked = stacked
                self?.view.setNeedsLayout()
                E3DSSetPaused(false)
            })
        }
        for factor in 1...3 {
            let title = NSLocalizedString("Resolution", comment: "3DS pause menu > Screens: internal render scale") + ": \(factor)x"
            sheet.addAction(UIAlertAction(title: mark(ThreeDSScreenPrefs.resolution == factor, title), style: .default) { [weak self] _ in
                guard let self, ThreeDSScreenPrefs.resolution != factor else { return E3DSSetPaused(false) }
                ThreeDSScreenPrefs.resolution = factor
                // ponytail: the core reads the scale at boot, so the game restarts (unsaved progress is lost; the save file is not).
                self.restartAfterStop = true
                E3DSStop()
            })
        }
        sheet.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in E3DSSetPaused(false) })
        sheet.popoverPresentationController?.sourceView = menuButton
        present(sheet, animated: true)
    }

    // MARK: - Cheats and saves

    /// The DS slot picker (slot 1 free, 2-4 PRO when saving). The core's calls
    /// block (up to ~7 s: pending async ops), so they run off the main thread
    /// behind a spinner; the game stays paused meanwhile.
    private func showStateSlots(_ mode: NDSSaveStateSlotsView.Mode) {
        let slots = (0..<4).map { slot -> NDSSaveStateSlotInfo in
            var t: Int64 = 0
            return NDSSaveStateSlotInfo(slot: slot, modifiedDate: E3DSStateInfo(Int32(slot), &t) ? Date(timeIntervalSince1970: TimeInterval(t)) : nil)
        }
        let picker = NDSSaveStateSlotsView(mode: mode, slots: slots, onSelectSlot: { [weak self] slot in
            self?.runStateOp(mode, slot: slot)
        })
        .onDisappear { [weak self] in
            if self?.stateOpInFlight == false { E3DSSetPaused(false) }
        }
        present(UIHostingController(rootView: picker), animated: true)
    }

    private func runStateOp(_ mode: NDSSaveStateSlotsView.Mode, slot: Int) {
        stateOpInFlight = true
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.center = view.center
        view.addSubview(spinner)
        spinner.startAnimating()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let code = mode == .save ? E3DSSaveState(Int32(slot)) : E3DSLoadState(Int32(slot))
            DispatchQueue.main.async {
                spinner.removeFromSuperview()
                guard let self else { return }
                let finish = {
                    self.stateOpInFlight = false
                    switch code {
                    case 0:
                        E3DSSetPaused(false)
                    case -6:
                        self.notice(NSLocalizedString("This save state was made by a different version of eDuo and can't be loaded.", comment: "3DS load state error"))
                    default:
                        self.notice(mode == .save
                            ? NSLocalizedString("The state couldn't be saved. Try again in a moment.", comment: "3DS save state error")
                            : NSLocalizedString("The state couldn't be loaded.", comment: "3DS load state error"))
                    }
                }
                // The slot sheet may still be up (or dismissing): a notice presented over it is dropped.
                if let sheet = self.presentedViewController { sheet.dismiss(animated: true, completion: finish) } else { finish() }
            }
        }
    }

    private func showCheats() {
        let cheats = NDSCheatsView(romBaseName: "", threeDSProgramID: programID, onCheatsChanged: { E3DSReloadCheats() })
            .onDisappear { E3DSSetPaused(false) }
        let host = UIHostingController(rootView: cheats)
        host.sheetPresentationController?.detents = [.medium(), .large()]
        present(host, animated: true)
    }

    /// The core's save folder for this game: `.../data/00000001/`, with
    /// `00000001.metadata` beside it once the game has formatted its save.
    private var saveFolder: URL? {
        guard let path = E3DSCopySaveFolder(programID) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func pickSaveToImport() {
        // A save folder the game never formatted has no metadata, and the
        // game would refuse it; one in-game save creates both.
        guard let folder = saveFolder,
              FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("00000001.metadata").path) else {
            return notice(NSLocalizedString("Start the game and save once, then import your save.", comment: "3DS save import: the game has no save yet"))
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .data])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func exportSave() {
        let fm = FileManager.default
        guard let folder = saveFolder, let files = try? fm.contentsOfDirectory(atPath: folder.path), !files.isEmpty else {
            return notice(NSLocalizedString("This game has no save yet.", comment: "3DS save export"))
        }
        let copy = fm.temporaryDirectory.appendingPathComponent(String(format: NSLocalizedString("%@ save", comment: "Exported 3DS save folder name"), rom.displayName))
        try? fm.removeItem(at: copy)
        guard (try? fm.copyItem(at: folder, to: copy)) != nil else { return E3DSSetPaused(false) }
        let picker = UIDocumentPickerViewController(forExporting: [copy], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Copies what was picked into a staging folder while the picker's
    /// access lasts. A folder counts as its contents: that is what a save
    /// manager exports (e.g. `main`), and what the core keeps per game.
    private func stageSave(from urls: [URL]) -> URL? {
        let fm = FileManager.default
        let staged = fm.temporaryDirectory.appendingPathComponent("save-import", isDirectory: true)
        try? fm.removeItem(at: staged)
        guard (try? fm.createDirectory(at: staged, withIntermediateDirectories: true)) != nil else { return nil }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let items = url.hasDirectoryPath ? (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] : [url]
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                // A raw console save (DISA container) is still encrypted
                // for that console; only a save manager's export works.
                if let head = try? FileHandle(forReadingFrom: item), let bytes = try? head.read(upToCount: 0x104),
                   bytes.count == 0x104, bytes.suffix(4) == Data("DISA".utf8) { return nil }
                guard (try? fm.copyItem(at: item, to: staged.appendingPathComponent(item.lastPathComponent))) != nil else { return nil }
            }
        }
        return (try? fm.contentsOfDirectory(atPath: staged.path))?.isEmpty == false ? staged : nil
    }

    private func replaceSave(with staged: URL) {
        let fm = FileManager.default
        guard let folder = saveFolder else { return }
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: staged.path)) ?? [] {
            try? fm.moveItem(at: staged.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
    }

    private func notice(_ message: String) {
        let alert = UIAlertController(title: rom.displayName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in E3DSSetPaused(false) })
        present(alert, animated: true)
    }

    static func message(for result: Int32) -> String? {
        switch UInt32(result) {
        case E3DSResultSuccess.rawValue, E3DSResultShutdownRequested.rawValue:
            return nil
        case E3DSResultErrorEncrypted.rawValue:
            return NSLocalizedString("This game file is encrypted. eDuo only opens decrypted copies: decrypt it on your own console first.", comment: "3DS load error")
        case E3DSResultErrorSystemFiles.rawValue:
            return NSLocalizedString("This game needs system files from your own console.", comment: "3DS load error")
        case E3DSResultErrorGetLoader.rawValue, E3DSResultErrorInvalidFormat.rawValue:
            return NSLocalizedString("This file is not a game eDuo can open.", comment: "3DS load error")
        default:
            return NSLocalizedString("This game could not be started.", comment: "3DS load error")
        }
    }

    deinit {
        if E3DSIsRunning() { E3DSStop() }
    }

    private static func code(for button: INDSButton) -> Int32 {
        let code: E3DSButton
        switch button {
        case .A: code = E3DSButtonA
        case .B: code = E3DSButtonB
        case .X: code = E3DSButtonX
        case .Y: code = E3DSButtonY
        case .L: code = E3DSButtonL
        case .R: code = E3DSButtonR
        case .start: code = E3DSButtonStart
        case .select: code = E3DSButtonSelect
        case .up: code = E3DSButtonUp
        case .down: code = E3DSButtonDown
        case .left: code = E3DSButtonLeft
        case .right: code = E3DSButtonRight
        @unknown default: return -1
        }
        return Int32(code.rawValue)
    }

    /// Same as the DS screen: a button stays down while any source holds it, and a
    /// controller release undone within 25 ms never reaches the game (no double press).
    private func input(_ button: INDSButton, pressed: Bool, source: String, graced: Bool) {
        switch pressMerger.handle(button: button.rawValue, pressed: pressed, source: source, graced: graced) {
        case .none:
            break
        case .press:
            apply(button, pressed: true)
        case .release(let delay, let token):
            guard delay > 0 else {
                if pressMerger.releaseFired(button: button.rawValue, token: token) { apply(button, pressed: false) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pressMerger.releaseFired(button: button.rawValue, token: token) else { return }
                self.apply(button, pressed: false)
            }
        }
    }

    private func apply(_ button: INDSButton, pressed: Bool) {
        let code = Self.code(for: button)
        if code >= 0 { E3DSSetButton(code, pressed) }
    }
}

extension ThreeDSGameViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller.documentPickerMode == .open else { return E3DSSetPaused(false) } // export done
        guard let staged = stageSave(from: urls) else {
            return notice(NSLocalizedString("That isn't a save eDuo can use. Pick the folder your save manager exported, with the save files inside.", comment: "3DS save import error"))
        }
        // The game restarts on the imported save once the core has let go of the old one.
        pendingSaveImport = staged
        E3DSStop()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        E3DSSetPaused(false)
    }
}

extension ThreeDSGameViewController: NDSControllerViewDelegate {
    func controllerView(_ view: NDSControllerView, setButton button: INDSButton, pressed: Bool) {
        input(button, pressed: pressed, source: "touch", graced: false)
    }
}

extension ThreeDSGameViewController: INDSGamepadManagerDelegate {
    func gamepadManager(_ manager: INDSGamepadManager, setButton button: INDSButton, pressed: Bool) {
        input(button, pressed: pressed, source: "gamepad", graced: true)
    }
    func gamepadManager(_ manager: INDSGamepadManager, perform action: INDSControllerAppAction) {
        if case .pause = action { showMenu() }
    }
    func gamepadManager(_ manager: INDSGamepadManager, setFastForwardActive active: Bool) {}
    func gamepadManagerDidChangeConnection(_ manager: INDSGamepadManager, connected: Bool) {
        applyGamepadConnectionState()
    }
}

extension ThreeDSGameViewController {
    /// Settings > Controls > "Hide with a Controller": only the button
    /// overlay goes; the bottom screen stays touchable.
    fileprivate func applyGamepadConnectionState() {
        let hide = INDSControllerOverlayPreferences.shouldHideOverlay(gamepadConnected: gamepadManager.isConnected)
        if hide { controllerView.releaseAllActiveInputs() }
        controllerView.isHidden = hide
        // "Also Hide the HUD": the controller's Menu button still opens the pause menu.
        menuButton.isHidden = hide && INDSControllerOverlayPreferences.hidesHUDWithGamepad
    }

    @objc fileprivate func gamepadOverlayPreferenceChanged() {
        applyGamepadConnectionState()
    }
}

/// The 3DS screen's own choices, kept apart from the DS layout settings.
enum ThreeDSScreenPrefs {
    /// Internal render scale; 2x keeps small text legible on a phone screen.
    static var resolution: Int {
        get { (UserDefaults.standard.object(forKey: "eduo.3ds.resolution") as? Int) ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "eduo.3ds.resolution") }
    }

    static var landscapeStacked: Bool {
        get { UserDefaults.standard.bool(forKey: "eduo.3ds.landscapeStacked") }
        set { UserDefaults.standard.set(newValue, forKey: "eduo.3ds.landscapeStacked") }
    }
}

/// A view whose backing layer is the CAMetalLayer the core presents into.
private final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

struct ThreeDSGameView: UIViewControllerRepresentable {
    let rom: ROMFile
    let onQuit: () -> Void

    func makeUIViewController(context: Context) -> ThreeDSGameViewController {
        ThreeDSGameViewController(rom: rom, onQuit: onQuit)
    }
    func updateUIViewController(_ controller: ThreeDSGameViewController, context: Context) {}
}
