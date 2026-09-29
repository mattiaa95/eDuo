import AVFoundation
import ReplayKit
import UIKit

/// Full emulation screen: dual DS screens, iGBA-style controller overlay,
/// pause menu, and HUD chrome. Owns the engine lifecycle wiring that was
/// already proven in the prototype (start/pause/resume/autosave, the
/// reused-framebuffer display link) and layers the ported/adapted iGBA UI
/// suite on top of it.
final class NDSRomViewController: UIViewController {
    private var rom: ROMFile
    private let core = MelonDSCoreBridge()

    /// Settings > Appearance's per-orientation background image (PRO), behind
    /// everything else. Empty and invisible when the user hasn't set one, in
    /// which case `view.backgroundColor` shows through as before.
    private let backgroundImageView = UIImageView()
    private let dualScreenView = DSDualScreenView()
    private let controllerView = NDSControllerView()
    private let hudView = NDSHUDView()
    private let gamepadManager = INDSGamepadManager()
    private let keyboardManager = INDSKeyboardManager()
    private let clipRecorder = NDSClipRecorder()

    private weak var pauseMenuController: NDSPauseMenuHostingController?
    private var orientationClass: DSScreenOrientationClass = .portrait
    private var lastOrientationClass: DSScreenOrientationClass?

    /// Which background image is currently applied ("" = none), so rotation
    /// and change notifications don't re-decode a multi-MB PNG for nothing.
    private var appliedSkinKey: String?

    /// What the user actually asked for — the pause menu's speed slider
    /// (`setSpeed`) or a per-game profile's remembered speed at load.
    /// `applyEffectiveSpeed()` is the only place this (plus the two
    /// transient modifiers below) ever reaches `core.speedMultiplier`;
    /// Fast Forward and Battery Saver both layer on top without ever
    /// mutating or persisting over this value.
    private var requestedSpeed: Double = 1.0

    /// Fast Forward: a controller's `INDSControllerAppAction.fastForward`
    /// hold, or the HUD's Speed button (a latch, cycled by tapping). Forces
    /// `activeFastForwardSpeed` while on, restoring `requestedSpeed` when it
    /// goes off.
    private var isFastForwardHeld = false

    /// The rate the line above runs at — the user's pick, whether it was
    /// made in Settings > Controls or by tapping the HUD's Speed button,
    /// which writes the same stored value. Never persisted from here: it is
    /// read at the moment Fast Forward switches on.
    private var activeFastForwardSpeed = INDSSpeedPreferences.defaultFastForwardSpeed
    private var periodicAutosaveTimer: Timer?

    /// The turbo buttons being held right now, and the pulse that switches
    /// them on and off. One timer for all of them: one per button buys
    /// nothing and drifts them out of step with each other.
    /// Time ACTUALLY played this session, for `INDSReviewPrompt`. It
    /// accumulates in stretches instead of subtracting two dates at the end,
    /// because backgrounding the app does NOT call `viewDidDisappear` — the
    /// view stays in the hierarchy — so a plain subtraction would count as
    /// play the hours the phone spent in a pocket with the game open.
    private var sessionPlayed: TimeInterval = 0
    private var sessionResumedAt: Date?

    private var turboHeld: Set<INDSButton> = []
    private var turboTimer: Timer?
    private var turboPhaseOn = true

    /// True the instant `refreshBatterySaverState()` last saw thermal
    /// `.critical` — guards the "Cooling down" toast to fire once on entry
    /// rather than on every notification while still critical.
    private var wasThermalCritical = false

    /// Edge-detect for the Battery Saver speed clamp, so the explanation
    /// toast fires when it engages rather than on every power/thermal
    /// notification while it stays engaged.
    private var wasSpeedClamped = false

    /// Mirrors whatever was last pushed to `dualScreenView.applyDisplayFilter`
    /// — kept around purely so `presentPauseMenu()` has a current value to
    /// hand the pause menu's filter card (there's no core-side equivalent to
    /// read back, unlike speed/volume).
    private var displayFilter: NDSDisplayFilter = .smooth

    private var displayLink: CADisplayLink?

    /// Last value pushed to `hudView.setMicActive`, so the display-link tick
    /// only touches the HUD badge on an actual transition instead of every
    /// frame (`core.microphoneActive` itself is a cheap ivar read — see
    /// MelonDSCoreBridge — but there's no reason to redo the label's
    /// isHidden/alpha work 60 times a second either).
    private var lastMicActive = false

    // Allocated once and reused every frame; the bridge copies pixels into
    // these instead of us allocating a new buffer/NSData per frame.
    private let topBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: 256 * 192)
    private let bottomBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: 256 * 192)

    /// Set by `NDSRomViewWrapper`. Called after the engine has been stopped
    /// and autosaved so the SwiftUI side can pop back to the ROM list.
    var onQuitToLibrary: (() -> Void)?

    /// Set once `quitToLibrary()` has already stopped and released the core,
    /// so the normal `viewDidDisappear` teardown (which also fires on a plain
    /// swipe-back) doesn't autosave/pause a second time on a torn-down core.
    private var didExplicitlyQuit = false

    /// `viewDidAppear` fires again after a cancelled swipe-back; the deferred
    /// ROM load must only ever be queued once.
    private var hasScheduledCoreLoad = false

    init(rom: ROMFile) {
        self.rom = rom
        super.init(nibName: nil, bundle: nil)
        topBuffer.initialize(repeating: 0, count: 256 * 192)
        bottomBuffer.initialize(repeating: 0, count: 256 * 192)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        releaseROMSlot() // backstop; the quit/teardown paths already did
        // Every live UIImage built by ndsFramebufferImage ALIASES these buffers
        // (zero-copy by design). Drop the ones that could outlive us before the
        // memory goes away, or they become CGImages over freed pages: the
        // external-display singleton holds the last top frame, and a dismissal
        // transition can still be holding a snapshot of our own image views.
        INDSExternalDisplayController.shared.present(topImage: nil)
        dualScreenView.topScreenView.image = nil
        dualScreenView.bottomScreenView.image = nil
        topBuffer.deallocate()
        bottomBuffer.deallocate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        observeHinge()
    }

    /// Duo half open = a DS on the table: `DSFoldableLayout` lifts the upper
    /// panel off the crease. Only the posture moves it — every other device
    /// has no hinge, so `isHalfOpen` never leaves false there.
    private func observeHinge() {
        // ponytail: UIHingeInteraction only exists in the iOS 27.1 SDK (UIKit
        // 9127.0.85); 27.0 is 9127.0.84. An older toolchain builds without it.
        #if canImport(UIKit, _version: 9127.0.85)
        guard #available(iOS 27.1, *) else { return }
        view.addInteraction(UIHingeInteraction { [weak self] _, update in
            let halfOpen = update.hinge?.status == .partiallyOpen
            guard let self, halfOpen != DSFoldableLayout.isHalfOpen else { return }
            DSFoldableLayout.isHalfOpen = halfOpen
            self.applyCurrentScreenLayout(animated: true)
            self.hudView.setNeedsLayout()
        })
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // One run-loop turn after the push has landed. The ROM load is
        // synchronous on the main thread (deliberately: the core is
        // main-thread only), and running it from viewDidLoad meant the
        // "Loading…" HUD never painted and the push itself stalled on large
        // carts. viewWillAppear has already run against the unloaded core
        // (resume/display link are no-ops there), so start for real here.
        guard !hasScheduledCoreLoad else { return }
        hasScheduledCoreLoad = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didExplicitlyQuit else { return }
            self.loadCore()
            self.core.resumeEmulation()
            self.startDisplayLink()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        registerLifecycleObservers()
        // External display (feature 8): re-layout the instant one connects
        // or disconnects, not just on the next rotation/layout pass.
        INDSExternalDisplayController.shared.onConnectionChanged = { [weak self] _ in
            self?.applyCurrentScreenLayout(animated: true)
        }
        core.resumeEmulation()
        startDisplayLink()
        startPeriodicAutosave()
        exitBookkeepingDone = false
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unregisterLifecycleObservers()
        INDSExternalDisplayController.shared.onConnectionChanged = nil
        stopDisplayLink()
        stopPeriodicAutosave()
        UIApplication.shared.isIdleTimerDisabled = false

        // A full-screen modal presented over the game (the ReplayKit clip
        // preview; the pause sheet itself in compact height) lands here too,
        // and we'll be back: the session record and the exit bookkeeping
        // belong to a real pop/dismiss only.
        let coveredByModal = presentedViewController != nil

        // Coming back to the library after playing is the moment to ask for a
        // rating: never mid-game, which is where it annoys and where people
        // tap three stars just to make the prompt go away. Queued, so it does
        // not fight the exit animation itself.
        if !coveredByModal, sessionPlayed > 0 {
            INDSReviewPrompt.recordSession(playedFor: sessionPlayed)
            sessionPlayed = 0
            DispatchQueue.main.async { INDSReviewPrompt.askIfEarned() }
        }
        guard !didExplicitlyQuit else { return }
        if !coveredByModal {
            runExitBookkeeping()
        }
        // Pause, not stop: this also fires when a full-screen modal (the
        // ReplayKit clip preview) covers us and we'll be back. The real
        // teardown is `stopForTeardown()`.
        core.pauseEmulation()
    }

    /// Set once the exit autosave/thumbnail ran for the current appearance,
    /// so a pop that lands right after `viewDidDisappear` doesn't write the
    /// same multi-megabyte state twice. Reset in `viewWillAppear`.
    private var exitBookkeepingDone = false

    private func runExitBookkeeping() {
        guard !exitBookkeepingDone else { return }
        exitBookkeepingDone = true
        clipRecorder.stopIfNeeded()
        autosaveIfNeeded()
        saveThumbnail()
        // Never leave the other-audio duck on across an exit that skipped
        // the `.end` hint (see handleSilenceSecondaryAudioHint).
        core.outputDucked = false
    }

    /// The SwiftUI pop — edge swipe-back or `dismiss()` — as opposed to the
    /// pause menu's "Quit to Library". `viewDidDisappear` can't tell a pop
    /// from a modal covering us, so it only pauses; without this the emu
    /// thread and audio engine outlived the screen until ARC got round to
    /// the controller, and re-opening the same ROM meanwhile could have two
    /// cores writing one `.sav`. Called from
    /// `NDSRomViewWrapper.dismantleUIViewController`.
    func stopForTeardown() {
        guard !didExplicitlyQuit else { return }
        didExplicitlyQuit = true
        stopDisplayLink() // before the thumbnail reads `topBuffer`
        runExitBookkeeping()
        core.stopEmulation()
        releaseROMSlot()
    }

    /// The only warning iOS gives before it jetsams us — and jetsam is the one
    /// exit that never reaches viewDidDisappear or didEnterBackground, so
    /// without this the whole session is lost. A DS core is a fat target: this
    /// fires far more often here than it would in a GBA emulator.
    ///
    /// Note: autosave only. Freeing caches would be the textbook response,
    /// but the memory is the core's working set — there is nothing to drop.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        guard core.loaded, !didExplicitlyQuit else { return }
        autosaveIfNeeded()
        // The one cache we do own: ~60 MB of rewind history.
        core.clearRewindHistory()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyLayoutForCurrentSize()
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    func update(rom: ROMFile) {
        self.rom = rom
    }

    // MARK: - App lifecycle (background pause + autosave)

    private func registerLifecycleObservers() {
        // viewWillAppear can fire twice with no viewDidDisappear in between
        // (cancelled swipe-back); without this each background would autosave
        // twice. removeObserver on a non-registered pair is a no-op.
        unregisterLifecycleObservers()
        let center = NotificationCenter.default
        center.addObserver(self,
                            selector: #selector(handleDidEnterBackground),
                            name: UIApplication.didEnterBackgroundNotification,
                            object: nil)
        center.addObserver(self,
                            selector: #selector(handleWillEnterForeground),
                            name: UIApplication.willEnterForegroundNotification,
                            object: nil)
        // Settings > Battery: re-derive the speed clamp/presentation cap
        // any time either signal changes, not just at launch — see
        // refreshBatterySaverState().
        center.addObserver(self,
                            selector: #selector(handleBatterySaverStateChanged),
                            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
                            object: nil)
        center.addObserver(self,
                            selector: #selector(handleBatterySaverStateChanged),
                            name: ProcessInfo.thermalStateDidChangeNotification,
                            object: nil)
        // Settings > Audio's "Mute While Other Audio Plays" — see the
        // Mute While Other Audio Plays section below.
        center.addObserver(self,
                            selector: #selector(handleSilenceSecondaryAudioHint(_:)),
                            name: AVAudioSession.silenceSecondaryAudioHintNotification,
                            object: nil)
    }

    private func unregisterLifecycleObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        center.removeObserver(self, name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        center.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.removeObserver(self, name: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil)
    }

    @objc private func handleDidEnterBackground() {
        // Ask iOS for time before doing any of this. Backgrounding gives an app
        // only a few seconds before it can be suspended mid-instruction, and
        // what runs here is a multi-megabyte save state plus a PNG thumbnail.
        // Suspended halfway through, the autosave lands truncated — and the
        // autosave is exactly what the next launch restores from.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "eNDS.autosave") {
            // Expiry handler: iOS is out of patience. Ending the task is
            // mandatory here or the app is killed outright.
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
        }

        autosaveIfNeeded()
        core.pauseEmulation()
        stopDisplayLink()
        saveThumbnail()

        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }

    @objc private func handleWillEnterForeground() {
        // Only resume automatically if we weren't sitting behind the pause menu.
        guard pauseMenuController == nil else { return }
        // The DS clock only advances while the core is stepping, so it has
        // been frozen for however long the app was away — re-seed it rather
        // than let the game drift further behind real time every session.
        applyConsoleClock()
        core.resumeEmulation()
        startDisplayLink()
    }

    /// Seeds the console's own RTC from Settings > Date & Time. Without this
    /// melonDS boots every game at 2000-01-01 (see `MelonDSCoreBridge`).
    private func applyConsoleClock() {
        guard core.loaded else { return }
        core.setConsoleDateTime(INDSRTCPreferences.componentsForCore())
    }

    /// Single choke point for every autosave call site (background, plain
    /// swipe-back/pause-less exit, explicit Quit) — so Settings > Saving's
    /// "Show Save Indicator" toast covers all three the same way "Saved to
    /// Slot %d" already covers every manual save.
    /// How often the periodic autosave fires while a game is running. Two
    /// minutes is the compromise: the snapshot costs one frame's stall, so
    /// often enough that a jetsam or a crash never costs much, rare enough that
    /// nobody notices it happening.
    private static let periodicAutosaveInterval: TimeInterval = 120

    /// Until this existed, autosave only ran on the way out (backgrounding,
    /// leaving the screen, quitting) — and jetsam, the most likely way a DS
    /// emulator dies, takes none of those paths. A whole session could vanish.
    private func startPeriodicAutosave() {
        periodicAutosaveTimer?.invalidate()
        guard INDSSavingPreferences.autoSaveOnExitEnabled else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.periodicAutosaveInterval,
                                         repeats: true) { [weak self] _ in
            self?.performPeriodicAutosave()
        }
        timer.tolerance = 15 // never worth waking the CPU precisely for this
        periodicAutosaveTimer = timer
    }

    private func stopPeriodicAutosave() {
        periodicAutosaveTimer?.invalidate()
        periodicAutosaveTimer = nil
    }

    /// Silent by design: no toast. The exit autosave announces itself because
    /// the user just acted; this one firing mid-battle would only distract.
    private func performPeriodicAutosave() {
        guard core.loaded, core.running, !didExplicitlyQuit,
              presentedViewController == nil, // not while the pause menu is up
              let path = core.autoSaveStatePathForROM() else { return }
        core.autosaveState(toPath: path)
        saveSlotThumbnail(-1)
    }

    private func autosaveIfNeeded() {
        guard INDSSavingPreferences.autoSaveOnExitEnabled else { return }
        guard core.loaded, let path = core.autoSaveStatePathForROM() else { return }
        do {
            try core.saveState(toPath: path)
            saveSlotThumbnail(-1)
            if INDSSavingPreferences.showSaveIndicatorEnabled {
                hudView.showToast(NSLocalizedString("Auto-saved", comment: "Autosave HUD toast"))
            }
        } catch {
            debugLog("Autosave failed: \(error.localizedDescription)")
        }
    }

    /// Captures the current top-screen frame as this ROM's "last played"
    /// library thumbnail (`Documents/Thumbnails/<baseName>.png`). Safe to call
    /// wherever the display link is already stopped — every call site below
    /// stops it first (or, for `quitToLibrary`, is only ever reached via the
    /// pause menu, which already stopped it) — so `topBuffer` can't be
    /// rewritten by `presentFrame()` while this reads it.
    private func saveThumbnail() {
        // COPY here, unlike the per-frame path: ThumbnailManager keeps the
        // image in a static NSCache and hands it to the library grid, so an
        // aliasing image would outlive topBuffer and the library would render
        // freed memory after quitting the game.
        guard core.loaded, let image = UIImage.ndsFramebufferImageCopy(from: topBuffer) else { return }
        ThumbnailManager.save(image, baseName: rom.baseName)
    }

    // MARK: - View setup

    private func configureView() {
        // Settings > Appearance's "Game Background" — read once here, same
        // "applies next time you open a game" convention as every other
        // Settings page (no live core/VC instance to push a mid-session
        // change into).
        view.backgroundColor = INDSAppearanceStore.shared.gameBackgroundUIColor

        backgroundImageView.frame = view.bounds
        backgroundImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isUserInteractionEnabled = false
        view.addSubview(backgroundImageView)
        applyBackgroundSkin(animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundSkinChanged),
                                               name: INDSBackgroundSkinStore.didChangeNotification, object: nil)

        dualScreenView.frame = view.bounds
        dualScreenView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Starts invisible over the (already dark/black) background —
        // `revealGameContent()` fades it in once `loadCore()` finishes
        // (success or failure), instead of the screens/chrome just being
        // there immediately while "Loading…" is still showing. Deliberately
        // never touched from `presentFrame()` itself (the display-link hot
        // path) — this is a one-shot reveal, not a per-frame animation.
        dualScreenView.alpha = 0
        view.addSubview(dualScreenView)

        controllerView.frame = view.bounds
        controllerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controllerView.delegate = self
        view.addSubview(controllerView)

        hudView.frame = view.bounds
        hudView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hudView.onPauseTapped = { [weak self] in self?.presentPauseMenu() }
        hudView.onCycleLayoutTapped = { [weak self] in self?.cycleScreenLayout() }
        hudView.onErrorBackTapped = { [weak self] in self?.quitToLibrary() }
        hudView.onFastForwardTapped = { [weak self] in self?.cycleFastForward() }
        view.addSubview(hudView)

        gamepadManager.delegate = self
        keyboardManager.delegate = self
        // A gamepad can already be connected by the time this view loads
        // (INDSGamepadManager scans for one in its own init, before its
        // delegate above was set) — sync the overlay/HUD to that now instead
        // of waiting for a connect/disconnect event that may never come.
        applyGamepadConnectionState(gamepadManager.isConnected)

        // Always-available way into the pause menu, and the reason hiding the
        // Menu button in the layout editor can't trap anyone: the top screen
        // takes no other gestures (only the bottom one is the touch panel).
        let menuPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTopScreenLongPress(_:)))
        menuPress.minimumPressDuration = 0.6
        dualScreenView.topScreenView.isUserInteractionEnabled = true
        dualScreenView.topScreenView.addGestureRecognizer(menuPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouchScreen(_:)))
        pan.maximumNumberOfTouches = 1
        dualScreenView.bottomScreenView.addGestureRecognizer(pan)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleTouchScreenPress(_:)))
        press.minimumPressDuration = 0
        dualScreenView.bottomScreenView.addGestureRecognizer(press)

        // Pure view-layer state (no core involved), so unlike per-game speed
        // this doesn't need to wait for loadCore() — safe to resolve as soon
        // as dualScreenView/rom.baseName exist.
        applyDisplayFilter(resolvedDisplayFilter())

        // clipRecorder's own isRecording is `@Published` for the pause
        // menu's SwiftUI row; this is the same fact mirrored imperatively
        // for the HUD (plain UIKit, no @ObservedObject).
        clipRecorder.onRecordingStateChanged = { [weak self] isRecording in
            self?.hudView.setRecordingActive(isRecording)
        }

        hudView.showLoading(NSLocalizedString("Loading…", comment: ""))
    }

    /// `allowAutoResume: false` is the recovery path: the whole point there is
    /// to boot from the cartridge save we just restored, so re-applying the
    /// auto state would immediately undo it.
    /// Base names of ROMs with a live core anywhere in the process. iPad
    /// multi-window (Stage Manager "New Window", drag-out) gives each window
    /// its own `NDSRomViewController`; two cores on one game would both
    /// flush the same `.sav` and autosave — last writer wins, silently.
    private static var openROMs: Set<String> = []
    private var registeredBaseName: String?

    private func releaseROMSlot() {
        if let name = registeredBaseName {
            Self.openROMs.remove(name)
            registeredBaseName = nil
        }
    }

    /// Returns whether the ROM booted. On failure the HUD already shows the
    /// error card, so callers must not resume or announce success.
    @discardableResult
    private func loadCore(allowAutoResume: Bool = true) -> Bool {
        let baseName = rom.baseName
        guard registeredBaseName == baseName || !Self.openROMs.contains(baseName) else {
            hudView.showError(NSLocalizedString("This game is already open in another window.", comment: "Emulator error: same ROM running in a second iPad window"))
            revealGameContent()
            return false
        }
        var booted = false
        do {
            // New session: this game is allowed one fresh battery-save snapshot
            // before whatever state load comes next.
            INDSSaveBackup.beginSession(baseName: rom.baseName)
            core.rewindEnabled = INDSSavingPreferences.rewindEnabled
            let biosDirectory = try ROMStorageManager.biosDirectoryURL()
            // Before the load, not after: the console's name and language are
            // baked into the firmware image, which is read once during boot
            // (unlike the clock below, which the core can be told at any time).
            INDSConsolePreferences.apply(to: core)
            // A session never starts ducked; the other-audio hint re-ducks it
            // if it has to (see handleSilenceSecondaryAudioHint).
            core.outputDucked = false
            try core.loadROM(atPath: rom.fileURL.path, biosDirectory: biosDirectory.path)
            Self.openROMs.insert(baseName)
            registeredBaseName = baseName
            applyPerGameProfileIfNeeded()
            applyCheats()
            applyConsoleClock()

            // Settings > Saving's "Resume Where You Left Off" (default ON).
            // Same path the pause menu's own Load State/auto-save row uses
            // (`performLoadFromSlot(-1)`) — a failure here is never user-
            // visible, just a debug log; the boot that already succeeded
            // above continues normally, fresh instead of resumed.
            if allowAutoResume, INDSSavingPreferences.autoResumeEnabled,
               core.hasAutoSaveState, let autoPath = core.autoSaveStatePathForROM() {
                do {
                    // A DS state carries the cartridge save RAM inside it, so
                    // this load will end up overwriting the .sav on the core's
                    // next flush — and it happens on EVERY launch. Snapshot the
                    // battery save first so "Recover Cartridge Save" can undo it.
                    INDSSaveBackup.backupBeforeStateLoad(baseName: rom.baseName)
                    try core.loadState(fromPath: autoPath)
                    // The state carries the RTC as it was when saved: re-seed,
                    // or the console clock rolls back with every resume.
                    applyConsoleClock()
                    hudView.showToast(NSLocalizedString("Resumed", comment: "Auto-resume HUD toast"))
                } catch {
                    debugLog("Auto-load save state failed: \(error.localizedDescription)")
                }
            }
            hudView.hideStatus()
            maybeShowFirstSessionHint()
            booted = true
        } catch {
            debugLog("ROM load failed: \(error.localizedDescription)")
            hudView.showError(error.localizedDescription)
        }
        revealGameContent()
        return booted
    }

    /// One-shot fade-in for the dual-screen container + HUD chrome once
    /// `loadCore()` is done, success or failure — see the two call sites
    /// above and the `alpha = 0` starting point set in `configureView()`.
    private func revealGameContent() {
        guard dualScreenView.alpha < 1 else { return }
        INDSMotion.fadeUIKit(duration: 0.35) {
            self.dualScreenView.alpha = 1
        }
        hudView.revealChrome()
        showMenuGestureHintIfNeeded()
    }

    /// Non-blocking "how do I pause/save/cheat" pill, shown once ever (not
    /// once per ROM) — gated by `eNDSHasSeenGameHint`.
    /// Scheduled a beat after the reveal above so it never races the
    /// "Resumed"/"Auto-saved" toast that can already be showing by the time
    /// this is called (both hide well within the delay below).
    private static let gameHintDefaultsKey = "eNDSHasSeenGameHint"

    private func maybeShowFirstSessionHint() {
        guard !UserDefaults.standard.bool(forKey: Self.gameHintDefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.gameHintDefaultsKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.hudView.showToast(
                NSLocalizedString("Tap ⏸ to pause · save · cheats", comment: "First-session coach hint, shown once after a game finishes loading"),
                holdDuration: 3.0
            )
        }
    }

    // MARK: - Screen layout (dual DS screens)

    /// Re-applies the current layout whenever the view crosses the
    /// portrait/landscape threshold. Within-orientation size changes (Split
    /// View resizing, etc.) are handled automatically by `DSDualScreenView`
    /// re-laying-out its *current* mode on every bounds change — this only
    /// needs to step in when the mode itself must change.
    private func applyLayoutForCurrentSize() {
        let content = view.bounds.inset(by: view.safeAreaInsets)
        guard content.width > 1, content.height > 1 else { return }
        let isLandscape = content.width > content.height
        let newClass: DSScreenOrientationClass = isLandscape ? .landscape : .portrait
        let orientationChanged = newClass != lastOrientationClass
        lastOrientationClass = newClass
        orientationClass = newClass

        if orientationChanged { applyBackgroundSkin(animated: true) }
        applyCurrentScreenLayout(animated: false)
    }

    @objc private func handleTopScreenLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        INDSHaptics.light()
        presentPauseMenu()
    }

    /// One-time nudge, shown only to someone who has actually hidden the Menu
    /// button, so they don't have to discover the long-press by accident.
    private func showMenuGestureHintIfNeeded() {
        let key = "eNDSHasSeenMenuGestureHint"
        guard !hudView.isPauseButtonVisible,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        hudView.showToast(NSLocalizedString("Hold the top screen to open the menu", comment: ""),
                          holdDuration: 3.5)
    }

    // MARK: - Background image (Settings > Appearance)

    @objc private func backgroundSkinChanged() {
        // The image behind a given orientation may have been *replaced*, which
        // `appliedSkinKey` alone can't see — force the reload.
        appliedSkinKey = nil
        applyBackgroundSkin(animated: true)
    }

    /// Swaps in the image for whichever orientation is on screen now. Read
    /// from disk each time rather than cached: the two images together can be
    /// several MB decoded, and this only runs on rotation or an explicit
    /// change, never per frame. Entitlement is re-checked here as well as at
    /// the picker, so a lapsed subscription stops applying the background
    /// instead of leaving a PRO feature switched on forever.
    private func applyBackgroundSkin(animated: Bool) {
        let orientation: INDSBackgroundSkinOrientation = orientationClass == .landscape ? .landscape : .portrait
        let entitled = EntitlementManager.shared.hasPro || INDSHoneymoon.isActive
        let key = entitled && INDSBackgroundSkinStore.hasSkin(for: orientation) ? orientation.rawValue : ""
        guard key != appliedSkinKey else { return }
        appliedSkinKey = key

        let image = key.isEmpty ? nil : INDSBackgroundSkinStore.image(for: orientation)
        let apply = { [weak self] in
            self?.backgroundImageView.image = image
            self?.backgroundImageView.alpha = image == nil ? 0 : 1
        }
        if animated {
            UIView.transition(with: backgroundImageView, duration: 0.28,
                              options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: apply)
        } else {
            apply()
        }
    }

    /// Single source of truth for what `dualScreenView` shows right now: the
    /// persisted mode/swap/stretch, *unless* an external display is
    /// connected (feature 8) — then the device always shows touch-only
    /// (bottom screen big, controller overlay on top — it's the gamepad
    /// now), regardless of orientation or the persisted mode, and the top
    /// screen goes to `INDSExternalDisplayController` instead. Every call
    /// site that used to poke `dualScreenView.applyLayout` directly
    /// (rotation, cycle, swap, stretch, connect/disconnect) now routes
    /// through here so none of them can stomp that override.
    private func applyCurrentScreenLayout(animated: Bool) {
        let mode: DSScreenLayoutMode = INDSExternalDisplayController.shared.isConnected
            ? .bottomOnly
            : DSScreenLayoutPreferences.mode(for: orientationClass, containerSize: view.bounds.inset(by: view.safeAreaInsets).size)
        controllerView.screenLayoutMode = mode
        controllerView.setNeedsLayout()
        dualScreenView.applyLayout(mode: mode, swap: DSScreenLayoutPreferences.swapEnabled,
                                    stretch: DSScreenLayoutPreferences.stretchEnabled, animated: animated)
        hudView.setLayoutIcon(mode)
    }

    /// Advances and persists the screen layout mode for the current
    /// orientation. Shared by the HUD cycle button and the pause menu row.
    @discardableResult
    private func cycleScreenLayout() -> DSScreenLayoutMode {
        // With a TV attached the on-device view is locked to the touch
        // screen, so cycling has no visible effect — advancing (and worse,
        // persisting to prefs + the per-game profile) here is exactly how a
        // user ended up permanently stuck in "Bottom Only" after
        // disconnecting: each blind tap kept recording a new mode. Explain
        // instead of silently mutating state the user can't see.
        guard !INDSExternalDisplayController.shared.isConnected else {
            hudView.showToast(NSLocalizedString("TV connected — showing touch screen here", comment: ""))
            return .bottomOnly
        }
        let newMode = DSScreenLayoutPreferences.cycleMode(for: orientationClass, containerSize: view.bounds.inset(by: view.safeAreaInsets).size)
        applyCurrentScreenLayout(animated: true)
        hudView.showToast(newMode.displayName)
        let settingName = orientationClass == .portrait ? "layoutPortrait" : "layoutLandscape"
        recordProfile(Self.layoutIndex(newMode), setting: settingName)
        return newMode
    }

    private func setScreenSwap(_ enabled: Bool) {
        DSScreenLayoutPreferences.swapEnabled = enabled
        applyCurrentScreenLayout(animated: true)
        recordProfile(enabled ? 1 : 0, setting: "screenSwap")
    }

    /// Pause menu's "Fill Screen" toggle — mirrors `setScreenSwap` above.
    private func setStretchEnabled(_ enabled: Bool) {
        DSScreenLayoutPreferences.stretchEnabled = enabled
        applyCurrentScreenLayout(animated: true)
    }

    // MARK: - Per-game profile (speed / layout / swap, remembered automatically)

    /// Applies this ROM's remembered speed/layout/swap overrides (if any) on
    /// top of the current global defaults — same tradeoff iGBA's own
    /// `PerGameProfileStore` accepts: a setting is only touched when this
    /// game actually has a recorded value, so a never-customized game leaves
    /// the global defaults (and the Screens settings page) alone. Called once
    /// per launch, after `loadROM` succeeds and before emulation starts.
    private func applyPerGameProfileIfNeeded() {
        let name = rom.baseName
        guard !name.isEmpty else { return }

        if let speed = INDSPerGameProfileStore.value("speedMultiplier", forGame: name) {
            // INDSPerGameProfileStore only stores Int, but 0.5x needs a
            // fractional value — recordProfile below stores speed*2 (a clean
            // Int for every half step) specifically so this divide-back-out
            // round-trips exactly instead of truncating 0.5 down to
            // Int(0.5) == 0.
            // Clamped to the speeds the UI still offers, so a profile
            // written by an older build cannot hold one that is gone.
            let resolvedSpeed = min(max(Double(speed) / 2.0, 0.5),
                                    INDSSpeedPreferences.speeds.last ?? 2.0)
            requestedSpeed = resolvedSpeed
            applyEffectiveSpeed()
        }
        if let raw = INDSPerGameProfileStore.value("layoutPortrait", forGame: name),
           let mode = Self.layoutMode(fromIndex: raw) {
            DSScreenLayoutPreferences.setMode(mode, for: .portrait)
        }
        if let raw = INDSPerGameProfileStore.value("layoutLandscape", forGame: name),
           let mode = Self.layoutMode(fromIndex: raw) {
            DSScreenLayoutPreferences.setMode(mode, for: .landscape)
        }
        if let raw = INDSPerGameProfileStore.value("screenSwap", forGame: name) {
            DSScreenLayoutPreferences.swapEnabled = raw != 0
        }
    }

    /// Records `value` under `setting` for the currently loaded ROM. Called
    /// from every pause menu / HUD action that already applies a change
    /// in-game (speed slider, layout cycle button, swap toggle) — the app
    /// "just remembers", no extra UI.
    private func recordProfile(_ value: Int, setting: String) {
        let name = rom.baseName
        guard !name.isEmpty else { return }
        INDSPerGameProfileStore.record(value, setting: setting, forGame: name)
    }

    private static func layoutMode(fromIndex index: Int) -> DSScreenLayoutMode? {
        let all = DSScreenLayoutMode.allCases
        guard all.indices.contains(index) else { return nil }
        return all[index]
    }

    private static func layoutIndex(_ mode: DSScreenLayoutMode) -> Int {
        DSScreenLayoutMode.allCases.firstIndex(of: mode) ?? 0
    }

    // MARK: - Cheats (Action Replay)

    /// Pushes this ROM's saved `.mch` cheat file (if any) into the freshly
    /// loaded core. Called once per launch, right after `loadROM` succeeds
    /// — the core always starts a session with an empty `AREngine.Cheats`
    /// (a brand new `NDS` instance is constructed on every `loadROMAtPath:`),
    /// so this is what makes cheats "re-apply on load" instead of only
    /// taking effect after the user opens the Cheats sheet. Also called from
    /// the pause menu's `onCheatsChanged` any time the list itself changes
    /// (add/edit/delete/toggle), so a toggle takes effect immediately.
    private func applyCheats() {
        guard let url = NDSCheatFileStore.fileURL(forBaseName: rom.baseName) else { return }
        // A list saved by an earlier version may hold CodeBreaker/CodeFreak
        // codes as typed; rewrite it in today's (translated) form first.
        NDSCheatFileStore.migrateIfNeeded(forBaseName: rom.baseName)
        core.reloadCheats(fromFile: url.path, enabled: true)
    }

    // MARK: - Display filter (smooth/crisp/scanlines)

    /// Resolves the effective filter for this ROM: a per-game override if
    /// one was ever recorded, else the Settings > Screens default — then
    /// clamps `.scanlines` down to `.smooth` if it needs an entitlement the
    /// user doesn't currently have right now. Same "recorded while
    /// entitled, since expired" defense as the speed clamp in
    /// `applyPerGameProfileIfNeeded`: a persisted `.scanlines` must never
    /// resurrect itself for a free/lapsed user just because it was saved to
    /// disk while they were entitled.
    private func resolvedDisplayFilter() -> NDSDisplayFilter {
        var filter = NDSDisplayFilterPreferences.current
        let name = rom.baseName
        if !name.isEmpty,
           let raw = INDSPerGameProfileStore.value("displayFilter", forGame: name),
           let saved = Self.displayFilter(fromIndex: raw) {
            filter = saved
        }
        let isEntitled = EntitlementManager.shared.hasPro
            || INDSHoneymoon.isActive
        return (filter.requiresEntitlement && !isEntitled) ? .smooth : filter
    }

    private func applyDisplayFilter(_ filter: NDSDisplayFilter) {
        displayFilter = filter
        dualScreenView.applyDisplayFilter(filter)
    }

    /// Applies + remembers a live change from the pause menu's filter card
    /// (the gate itself already ran there before this is ever called).
    private func setDisplayFilter(_ filter: NDSDisplayFilter) {
        applyDisplayFilter(filter)
        recordProfile(Self.displayFilterIndex(filter), setting: "displayFilter")
    }

    private static func displayFilter(fromIndex index: Int) -> NDSDisplayFilter? {
        let all = NDSDisplayFilter.allCases
        guard all.indices.contains(index) else { return nil }
        return all[index]
    }

    private static func displayFilterIndex(_ filter: NDSDisplayFilter) -> Int {
        NDSDisplayFilter.allCases.firstIndex(of: filter) ?? 0
    }

    // MARK: - Battery Saver (Settings > Battery)
    //
    // Two independent, transient modifiers — neither ever persists (not to
    // UserDefaults, not to the per-game profile): they only ever change what
    // `applyEffectiveSpeed()` sends to `core.speedMultiplier` and what
    // `displayLink.preferredFrameRateRange` presents at, restoring exactly
    // what the user had (`requestedSpeed`, 60fps) the instant the condition
    // clears.

    private var isBatterySpeedClampActive: Bool {
        if INDSBatterySaverPreferences.respectLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }
        if INDSBatterySaverPreferences.autoThrottleWhenHot {
            switch ProcessInfo.processInfo.thermalState {
            case .serious, .critical: return true
            default: break
            }
        }
        return false
    }

    private var isBatteryPresentationThrottleActive: Bool {
        if INDSBatterySaverPreferences.respectLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }
        return INDSBatterySaverPreferences.autoThrottleWhenHot && ProcessInfo.processInfo.thermalState == .critical
    }

    /// The only place `core.speedMultiplier` is ever written outside of
    /// this method's three callers (`setSpeed`, `setFastForwardHold`,
    /// `refreshBatterySaverState`) composing `requestedSpeed` with Fast
    /// Forward's chosen rate and then the Battery Saver clamp, in that
    /// order — the clamp always wins, even while Fast Forward is held.
    private func applyEffectiveSpeed() {
        var speed = isFastForwardHeld ? activeFastForwardSpeed : requestedSpeed
        if isBatterySpeedClampActive {
            speed = min(speed, 1.0)
        }
        core.speedMultiplier = speed
    }

    /// True when Battery Saver is actively holding the game below the speed
    /// the user asked for. Until 1.0(12) this happened in total silence, so
    /// picking 2x with Low Power Mode on (or a warm device) simply did
    /// nothing and looked like a broken feature.
    private var isSpeedBeingClamped: Bool {
        isBatterySpeedClampActive
            && max(requestedSpeed, isFastForwardHeld ? activeFastForwardSpeed : 0) > 1.0
    }

    private func warnIfSpeedClamped() {
        guard isSpeedBeingClamped else { return }
        hudView.showToast(NSLocalizedString("Battery Saver is holding speed at 1x — see Settings > Battery",
                                            comment: "Battery saver speed clamp toast"),
                          holdDuration: 3.0)
    }

    /// Re-derives both the speed clamp and the presentation frame-rate cap
    /// from scratch every time (same "recompute, don't react to the specific
    /// edge" idiom as the bridge's own `-refreshMicrophoneCaptureState`) —
    /// called on every LPM/thermal-state change notification, and once
    /// whenever emulation (re)starts via `startDisplayLink()`.
    @objc private func handleBatterySaverStateChanged() {
        refreshBatterySaverState()
    }

    private func refreshBatterySaverState() {
        applyEffectiveSpeed()

        displayLink?.preferredFrameRateRange = isBatteryPresentationThrottleActive
            ? CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

        let isCritical = INDSBatterySaverPreferences.autoThrottleWhenHot
            && ProcessInfo.processInfo.thermalState == .critical
        if isCritical, !wasThermalCritical {
            hudView.showToast(NSLocalizedString("Cooling down", comment: "Battery saver thermal throttle toast"))
        } else if isSpeedBeingClamped, !wasSpeedClamped {
            warnIfSpeedClamped()
        }
        wasThermalCritical = isCritical
        wasSpeedClamped = isSpeedBeingClamped
    }

    // MARK: - Mute While Other Audio Plays (Settings > Audio)
    //
    // Deliberately mutes via `core.outputDucked` — a transient output-level
    // gain that is never persisted, unlike `audioVolume`, which is the user's
    // own setting and used to survive a quit mid-duck as a silent app —
    // instead of
    // switching the session to `.soloAmbient` — MelonDSCoreBridge.mm already
    // owns every `AVAudioSession` category change (.ambient at rest,
    // .playAndRecord for the Mic_Start...Mic_Stop window, see its
    // Microphone section) and documents that category switch as funneling
    // through one call site; going through `outputDucked` instead never
    // touches the category at all, so there's nothing here for the bridge's
    // own switching to race against.

    @objc private func handleSilenceSecondaryAudioHint(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let hintType = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return }

        switch hintType {
        case .begin:
            guard INDSAudioPreferences.muteWithOtherAudioEnabled, !core.outputDucked else { return }
            // Cede priority to the DS mic: don't duck output out from under
            // a game that's actively listening right now.
            guard !core.microphoneActive else { return }
            core.outputDucked = true
        case .end:
            // Restored unconditionally (not re-gated on the toggle still
            // being on) so flipping it off mid-duck can never leave the
            // game stuck silent.
            core.outputDucked = false
        @unknown default:
            break
        }
    }

    // MARK: - Presentation (display link)

    /// Presents the latest completed emulation frame. The emulation itself
    /// runs on its own paced thread (see MelonDSCoreBridge); this display
    /// link only pulls whatever frame is ready at the display's refresh
    /// rate, so it's fine for it to redraw the same frame more than once.
    private func startDisplayLink() {
        guard displayLink == nil, core.loaded else { return }
        let link = CADisplayLink(target: self, selector: #selector(presentFrame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        // The session clock hangs off this and not off the view lifecycle:
        // this is the only thing that really knows whether the game is
        // running. It covers all three cases at once — first appearance,
        // return from background and resume from the pause menu — and keeps
        // time spent with the menu open, or with the phone in a pocket, out of
        // the total. Hooking `viewWillAppear` did not work: backgrounding does
        // not tear the view down.
        resumeSessionClock()
        // Covers every re-entry point in one place (first appearance,
        // foreground return, resume-from-pause): a Low Power/thermal state
        // that was already active before emulation (re)started must clamp
        // immediately, not wait for the next ProcessInfo notification.
        refreshBatterySaverState()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        pauseSessionClock()
        // Pausing while a turbo button was held used to leave the key down
        // inside the emulator: touches are cancelled when the menu appears,
        // but the pulse stayed alive and the last phase could be left "on".
        releaseTurboButtons()
        // presentFrame won't tick again to notice pauseEmulation/
        // stopEmulation already silenced the mic (both do, synchronously,
        // before every call site that stops the display link) — clear the
        // badge here instead of leaving it stuck showing "Listening" behind
        // the pause menu / library.
        if lastMicActive {
            lastMicActive = false
            hudView.setMicActive(false)
        }
    }

    @objc private func presentFrame() {
        // Self-throttling to once a second inside the bridge; see
        // -ensureAudioIsRunning. The frame loop is just the only main-thread
        // heartbeat a running game is guaranteed to have.
        core.ensureAudioIsRunning()
        if core.microphoneActive != lastMicActive {
            lastMicActive = core.microphoneActive
            hudView.setMicActive(lastMicActive)
        }
        guard core.copyFramebuffersTop(topBuffer, bottom: bottomBuffer) else { return }
        // Shared with INDSExternalDisplayController below: the top screen
        // renders identically whether it's on-device or mirrored to an
        // external display, so build the UIImage once either way.
        let topImage = UIImage.ndsFramebufferImage(from: topBuffer)
        dualScreenView.topScreenView.image = topImage
        dualScreenView.bottomScreenView.image = .ndsFramebufferImage(from: bottomBuffer)
        INDSExternalDisplayController.shared.present(topImage: topImage)
    }

    // MARK: - Touch screen (bottom/touch DS screen)

    @objc private func handleTouchScreen(_ recognizer: UIPanGestureRecognizer) {
        updateTouch(recognizer)
    }

    @objc private func handleTouchScreenPress(_ recognizer: UILongPressGestureRecognizer) {
        updateTouch(recognizer)
    }

    /// Maps a touch to DS coordinates (256×192, aspect-fit, clamped). A touch
    /// that drags outside the screen's own bounds counts as lifted (spec:
    /// "touch outside = ReleaseScreen") instead of clamping-and-holding at the
    /// edge, matching how a real stylus behaves when it slides off the glass.
    private func updateTouch(_ recognizer: UIGestureRecognizer) {
        let screen = dualScreenView.bottomScreenView
        let bounds = screen.bounds
        let point = recognizer.location(in: screen)

        switch recognizer.state {
        case .began, .changed:
            guard bounds.width > 1, bounds.height > 1, bounds.contains(point) else {
                core.setTouchX(0, y: 0, pressed: false)
                return
            }
            let x = Int(((point.x / bounds.width) * 255).rounded())
            let y = Int(((point.y / bounds.height) * 191).rounded())
            core.setTouchX(max(0, min(255, x)), y: max(0, min(191, y)), pressed: true)
        default:
            core.setTouchX(0, y: 0, pressed: false)
        }
    }

    // MARK: - External input (gamepad + keyboard)

    /// Shared by both `INDSGamepadManagerDelegate` and
    /// `INDSKeyboardManagerDelegate` — Quick Save/Load always target slot 0
    /// (there is no in-game UI to pick a different slot for a hotkey), Cycle
    /// Layout and Swap Screens reuse the exact same private operations the
    /// HUD button and pause menu rows already call.
    ///
    /// Deliberate policy: Quick Save overwrites slot 1 with NO confirmation —
    /// a hotkey that asks a question stops being quick. The overwrite
    /// confirmation lives only in the Save State sheet; whoever binds the
    /// hotkey is choosing these semantics. The previous state also stays
    /// recoverable as long as it is not overwritten twice (atomic write, see
    /// saveStateToPath).
    private func performControllerAction(_ action: INDSControllerAppAction) {
        switch action {
        case .pause:
            presentPauseMenu()
        case .quickSave:
            performSaveToSlot(0)
        case .quickLoad:
            performLoadFromSlot(0)
        case .cycleScreenLayout:
            cycleScreenLayout()
        case .swapScreens:
            setScreenSwap(!DSScreenLayoutPreferences.swapEnabled)
        case .fastForward:
            break // hold state, routed through setFastForwardHold(_:) instead
        }
    }

    /// While on: forces the chosen Fast Forward rate (still subject to
    /// Battery Saver's clamp, same as every other speed source — see
    /// `applyEffectiveSpeed()`). When it goes off: restores `requestedSpeed`
    /// (the pause menu slider or a per-game profile) — never compounds with
    /// it. `speed` is the rate to run at; omitted means the stored pick,
    /// which is what a controller's hold always uses.
    private func setFastForwardHold(_ active: Bool, speed: Double? = nil) {
        let rate = speed ?? INDSSpeedPreferences.fastForwardSpeed
        // Also runs when only the rate changed (the HUD button cycling from
        // 2x to 3x): same `active`, different speed, and the core still has
        // to hear about it.
        guard isFastForwardHeld != active || (active && activeFastForwardSpeed != rate) else { return }
        isFastForwardHeld = active
        if active { activeFastForwardSpeed = rate }
        // Keep the HUD pill in step whichever input drove this — a gamepad hold
        // and the on-screen button share one piece of state.
        hudView.setFastForwardSpeed(active ? rate : nil)
        applyEffectiveSpeed()
    }

    /// The on-screen Speed button is a latch, not a hold: each tap steps to
    /// the next rate and the one after the fastest switches it off. The rate
    /// it lands on is stored, so a controller's Fast Forward hold runs at
    /// whatever was last picked here and Settings > Controls shows it.
    private func cycleFastForward() {
        let current = isFastForwardHeld ? activeFastForwardSpeed : nil
        guard let next = INDSSpeedPreferences.nextFastForwardSpeed(after: current) else {
            setFastForwardHold(false)
            return
        }
        INDSSpeedPreferences.fastForwardSpeed = next
        setFastForwardHold(true, speed: next)
        warnIfSpeedClamped()
    }

    /// Hides/shows the touch overlay opposite a gamepad's connection state
    /// and mirrors it in the HUD badge. Uses the overlay's own existing
    /// `releaseAllActiveInputs()` so a finger mid-touch when a controller
    /// connects doesn't leave a phantom button stuck down.
    private func applyGamepadConnectionState(_ connected: Bool) {
        // Screenshot harness: the sim's host keyboard registers as a
        // connected gamepad, which would hide the touch overlay in every
        // capture — keep the real no-controller presentation instead.
        let effective = connected && !INDSLaunchFlags.screenshotHarness
        controllerView.releaseAllActiveInputs()
        controllerView.isHidden = effective
        // No on-screen controls to leave room for — give the strip back to
        // the screens (portrait only; see `DSDualScreenView`).
        dualScreenView.reservesControlBand = !effective
        hudView.setGamepadConnected(effective)
    }

    // MARK: - Pause menu

    private func presentPauseMenu() {
        // `core.loaded`: nothing to pause, save or resume behind the
        // load-error card — its own Back button is the only way out.
        guard core.loaded, pauseMenuController == nil, presentedViewController == nil else { return }

        core.pauseEmulation()
        stopDisplayLink()
        saveThumbnail()
        hudView.setPauseIcon(paused: true)

        let controller = NDSPauseMenuHostingController(
            romTitle: rom.displayName,
            romBaseName: rom.baseName,
            // The user's own choice, not `core.speedMultiplier`: that is the
            // effective speed after Fast Forward / Battery Saver, and seeding
            // the slider with it recorded the transient value as a request.
            currentSpeed: requestedSpeed,
            saveSlots: saveStateSlotInfos(includeAuto: false),
            loadSlots: saveStateSlotInfos(includeAuto: true),
            currentVolume: core.audioVolume,
            currentLayoutMode: DSScreenLayoutPreferences.mode(for: orientationClass, containerSize: view.bounds.inset(by: view.safeAreaInsets).size),
            currentSwapEnabled: DSScreenLayoutPreferences.swapEnabled,
            currentStretchEnabled: DSScreenLayoutPreferences.stretchEnabled,
            canRewind: core.canRewind,
            currentDisplayFilter: displayFilter,
            clipRecorder: clipRecorder,
            onAction: { [weak self] action in self?.handlePauseMenuAction(action) },
            onResume: { [weak self] in self?.handleResumeFromMenu() },
            onSpeedChanged: { [weak self] speed in self?.setSpeed(speed) },
            onVolumeChanged: { [weak self] volume in self?.core.audioVolume = volume },
            onCycleLayout: { [weak self] in self?.cycleScreenLayout() ?? .stacked },
            onToggleSwap: { [weak self] enabled in self?.setScreenSwap(enabled) },
            onToggleStretch: { [weak self] enabled in self?.setStretchEnabled(enabled) },
            onCheatsChanged: { [weak self] in self?.applyCheats() },
            onDisplayFilterChanged: { [weak self] filter in self?.setDisplayFilter(filter) },
            onToggleClipRecording: { [weak self] in self?.toggleClipRecording() }
        )
        pauseMenuController = controller
        present(controller, animated: true)
    }

    private func setSpeed(_ speed: Double) {
        requestedSpeed = speed
        applyEffectiveSpeed()
        warnIfSpeedClamped()
        // *2 so 0.5x round-trips through the profile store's Int-only
        // storage exactly — see applyPerGameProfileIfNeeded's /2.0 above.
        recordProfile(Int(speed * 2), setting: "speedMultiplier")
    }

    private func handlePauseMenuAction(_ action: NDSPauseMenuAction) {
        switch action {
        case .reset:
            dismiss(animated: true) { [weak self] in
                self?.core.resetEmulation()
                self?.resumeFromPause()
            }
            pauseMenuController = nil

        case .quitToLibrary:
            dismiss(animated: true) { [weak self] in
                self?.quitToLibrary()
            }
            pauseMenuController = nil

        case .saveToSlot(let slot):
            // Deliberately does not dismiss: a quick save is meant to let the
            // user keep browsing the menu (e.g. save then also check Audio),
            // matching iGBA's own "Save Game" row (also non-dismissing).
            performSaveToSlot(slot)

        case .loadFromSlot(let slot):
            performLoadFromSlot(slot)

        case .rewind:
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                // Same hazard as a state load: the capture's cartridge save
                // lands on the .sav.
                INDSSaveBackup.backupBeforeStateLoad(baseName: self.rom.baseName)
                if self.core.rewindTenSeconds() {
                    self.applyConsoleClock()
                } else {
                    self.hudView.showToast(NSLocalizedString("Couldn't rewind", comment: "Rewind failed toast"))
                }
                self.resumeFromPause()
            }
            pauseMenuController = nil

        case .recoverCartridgeSave:
            dismiss(animated: true) { [weak self] in
                self?.recoverCartridgeSave()
                // Resets the HUD pause icon; the second `dismiss` that used to
                // do this raced the first one and could leave it stuck on ⏸.
                self?.resumeFromPause()
            }
            pauseMenuController = nil
        }
    }

    private func handleResumeFromMenu() {
        if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in self?.resumeFromPause() }
        } else {
            resumeFromPause()
        }
        pauseMenuController = nil
    }

    private func resumeFromPause() {
        core.resumeEmulation()
        startDisplayLink()
        hudView.setPauseIcon(paused: false)
    }

    /// The pause menu's "Record Clip" / "Stop Recording" row. Deliberately
    /// doesn't dismiss the pause menu either way (same as Save State) — the
    /// row's own label/red-dot (driven by `clipRecorder.isRecording`, an
    /// `@ObservedObject`) reflects the new state live while the sheet stays
    /// open, and the HUD's REC badge (via `onRecordingStateChanged`) picks
    /// it up too for once the sheet is dismissed.
    private func toggleClipRecording() {
        clipRecorder.toggle { [weak self] preview in
            preview.previewControllerDelegate = self
            self?.presentClipPreview(preview)
        }
    }

    /// Presents the finished clip from whichever controller is on top right
    /// now. Stopping is triggered from inside the pause menu sheet, but
    /// ReplayKit finishes asynchronously — by then the user may already have
    /// tapped Resume, leaving the sheet mid-dismissal: presenting from it,
    /// or from `self` while it still has a presented controller, is refused
    /// by UIKit and the preview silently never shows. Wait for the dismissal
    /// to settle instead.
    private func presentClipPreview(_ preview: RPPreviewViewController) {
        guard !didExplicitlyQuit else { return }
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        if top !== self, top.isBeingDismissed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.presentClipPreview(preview)
            }
            return
        }
        top.present(preview, animated: true)
    }

    private func quitToLibrary() {
        didExplicitlyQuit = true
        clipRecorder.stopIfNeeded()
        autosaveIfNeeded()
        saveThumbnail()
        core.stopEmulation()
        stopDisplayLink()
        releaseROMSlot()
        // Short fade instead of the screens just vanishing under the pop
        // transition — mirrors the entry fade in `revealGameContent()`.
        guard dualScreenView.alpha > 0 else {
            onQuitToLibrary?()
            return
        }
        INDSMotion.fadeUIKit(duration: 0.16, options: [.curveEaseIn]) {
            self.dualScreenView.alpha = 0
        } completion: { [weak self] _ in
            self?.onQuitToLibrary?()
        }
    }

    private func performSaveToSlot(_ slot: Int) {
        guard let path = core.path(forSaveStateSlot: slot) else { return }
        do {
            try core.saveState(toPath: path)
            saveSlotThumbnail(slot)
            hudView.showToast(String(format: NSLocalizedString("Saved to Slot %d", comment: ""), slot + 1))
        } catch {
            debugLog("Save to slot \(slot) failed: \(error.localizedDescription)")
            hudView.showToast(String(format: NSLocalizedString("Couldn't save state: %@", comment: ""), error.localizedDescription))
        }
    }

    // MARK: - Session clock (for the review prompt)

    private func resumeSessionClock() {
        if sessionResumedAt == nil { sessionResumedAt = Date() }
    }

    private func pauseSessionClock() {
        guard let resumed = sessionResumedAt else { return }
        sessionPlayed += Date().timeIntervalSince(resumed)
        sessionResumedAt = nil
    }

    // MARK: - Input (turbo)

    /// The single point all three input sources pass through (touch overlay,
    /// game controller and keyboard). Turbo lives here and not in touch
    /// handling for exactly that reason: a button marked as turbo auto-fires
    /// whichever way it is being driven.
    private func applyButton(_ button: INDSButton, pressed: Bool) {
        guard INDSTurboPreferences.isTurbo(button) else {
            core.setButton(button, pressed: pressed)
            return
        }
        if pressed {
            turboHeld.insert(button)
            // The first press goes in immediately: waiting for the first
            // pulse feels like the button did not respond. The WHOLE chord is
            // re-pressed, not just the new button: if the phase was OFF, the
            // ones already on turbo would sit released until the next tick.
            turboPhaseOn = true
            for held in turboHeld { core.setButton(held, pressed: true) }
            startTurboTimer()
        } else {
            turboHeld.remove(button)
            core.setButton(button, pressed: false)
            if turboHeld.isEmpty { stopTurboTimer() }
        }
    }

    /// 15 pulses per second: each phase lasts ~2 of the 60 frames at which
    /// the game reads the keypad, so none is lost. Any faster and some games
    /// start dropping presses.
    // Note: a Timer, not the display link — frame accuracy is not needed
    // here and coupling it to the video loop complicates it for nothing.
    private func startTurboTimer() {
        guard turboTimer == nil else { return }
        turboTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.turboPhaseOn.toggle()
            for button in self.turboHeld {
                self.core.setButton(button, pressed: self.turboPhaseOn)
            }
        }
    }

    private func stopTurboTimer() {
        turboTimer?.invalidate()
        turboTimer = nil
    }

    /// Releases everything that was on turbo. Without this, pausing with a
    /// button held leaves the key down inside the emulator forever.
    private func releaseTurboButtons() {
        stopTurboTimer()
        for button in turboHeld { core.setButton(button, pressed: false) }
        turboHeld.removeAll()
    }

    /// Saves the top screen's frame next to the slot's `.mln`. Four identical
    /// rows with nothing but a date do not say which to load or which can be
    /// sacrificed. `slot < 0` is the auto-save.
    // Note: the periodic auto-save calls in here with the display link
    // alive, so `topBuffer` can be read mid-write. The worst that comes out is
    // a thumbnail with a band of two different frames; pausing the loop just
    // for this would cost more than it fixes. If it ever becomes a nuisance,
    // the way out is to capture inside `presentFrame`.
    private func saveSlotThumbnail(_ slot: Int) {
        guard core.loaded, let image = UIImage.ndsFramebufferImageCopy(from: topBuffer) else { return }
        NDSSaveStatePaths.saveThumbnail(image, baseName: rom.baseName, slot: slot)
    }

    /// Puts the battery save back as it was before this session's first state
    /// load, then reboots the game from it.
    ///
    /// The reboot is mandatory, not cosmetic: the core only reads `savePath`
    /// inside `loadROMAtPath:` (`resetEmulation` just does Reset +
    /// SetupDirectBoot), so without a full reload it would keep running on the
    /// save RAM it already holds and flush that straight back over the file we
    /// just restored.
    private func recoverCartridgeSave() {
        stopDisplayLink()
        core.pauseEmulation()
        guard INDSSaveBackup.restore(baseName: rom.baseName) else {
            hudView.showToast(NSLocalizedString("No save to recover", comment: "Recover cartridge save failed toast"))
            core.resumeEmulation()
            startDisplayLink()
            return
        }
        hudView.showLoading(NSLocalizedString("Loading…", comment: ""))
        // A failed reload has already put up the error card; there is
        // nothing to resume and no recovery to announce.
        guard loadCore(allowAutoResume: false) else { return }
        core.resumeEmulation()
        startDisplayLink()
        hudView.showToast(NSLocalizedString("Cartridge save recovered", comment: "Recover cartridge save success toast"))
    }

    private func performLoadFromSlot(_ slot: Int) {
        let path = slot < 0 ? core.autoSaveStatePathForROM() : core.path(forSaveStateSlot: slot)
        guard let path else { return }
        do {
            // Same hazard as auto-resume: the state's embedded cartridge save
            // will land on the .sav at the core's next flush.
            INDSSaveBackup.backupBeforeStateLoad(baseName: rom.baseName)
            try core.loadState(fromPath: path)
            // The state carries the RTC as it was when saved: re-seed, or
            // the console clock rolls back with every load.
            applyConsoleClock()
        } catch {
            debugLog("Load from slot \(slot) failed: \(error.localizedDescription)")
            hudView.showToast(String(format: NSLocalizedString("Couldn't load state: %@", comment: ""), error.localizedDescription))
        }
    }

    /// Builds slot info (with on-disk timestamps) for the pause menu's
    /// Save/Load sheets. `includeAuto` prepends the dedicated auto-save
    /// entry (Load only — auto-save is system-managed, never a save target).
    private func saveStateSlotInfos(includeAuto: Bool) -> [NDSSaveStateSlotInfo] {
        var infos: [NDSSaveStateSlotInfo] = []
        if includeAuto, core.hasAutoSaveState, let autoPath = core.autoSaveStatePathForROM() {
            infos.append(NDSSaveStateSlotInfo(slot: -1, modifiedDate: modificationDate(atPath: autoPath)))
        }
        for slot in 0..<4 {
            guard let path = core.path(forSaveStateSlot: slot) else { continue }
            infos.append(NDSSaveStateSlotInfo(slot: slot, modifiedDate: modificationDate(atPath: path)))
        }
        return infos
    }

    private func modificationDate(atPath path: String) -> Date? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}

// MARK: - NDSControllerViewDelegate

extension NDSRomViewController: NDSControllerViewDelegate {
    func controllerView(_ view: NDSControllerView, setButton button: INDSButton, pressed: Bool) {
        applyButton(button, pressed: pressed)
    }
}

// MARK: - INDSGamepadManagerDelegate

extension NDSRomViewController: INDSGamepadManagerDelegate {
    func gamepadManager(_ manager: INDSGamepadManager, setButton button: INDSButton, pressed: Bool) {
        applyButton(button, pressed: pressed)
    }

    func gamepadManager(_ manager: INDSGamepadManager, perform action: INDSControllerAppAction) {
        performControllerAction(action)
    }

    func gamepadManager(_ manager: INDSGamepadManager, setFastForwardActive active: Bool) {
        setFastForwardHold(active)
    }

    func gamepadManagerDidChangeConnection(_ manager: INDSGamepadManager, connected: Bool) {
        applyGamepadConnectionState(connected)
    }
}

// MARK: - INDSKeyboardManagerDelegate

extension NDSRomViewController: INDSKeyboardManagerDelegate {
    func keyboardManager(_ manager: INDSKeyboardManager, setButton button: INDSButton, pressed: Bool) {
        applyButton(button, pressed: pressed)
    }

    func keyboardManagerDidRequestPause(_ manager: INDSKeyboardManager) {
        performControllerAction(.pause)
    }
}

// MARK: - RPPreviewViewControllerDelegate (Record Clip)

extension NDSRomViewController: RPPreviewViewControllerDelegate {
    /// ReplayKit never dismisses this itself — required, or a finished clip
    /// preview would just sit on screen forever. Both delegate methods are
    /// implemented (RPPreviewViewController.h documents both as firing "when
    /// the view controller is finished") and just do the same thing —
    /// dismissing an already-dismissed view controller is a harmless no-op,
    /// and this is cheap insurance against relying on only one of them.
    func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
        previewController.dismiss(animated: true)
    }

    func previewController(_ previewController: RPPreviewViewController, didFinishWithActivityTypes activityTypes: Set<String>) {
        previewController.dismiss(animated: true)
    }
}

// MARK: - Framebuffer → UIImage

private extension UIImage {
    /// Builds a UIImage view onto a caller-owned, reused pixel buffer with no
    /// per-frame copy: the CGDataProvider wraps the pointer directly with a
    /// no-op release callback since NDSRomViewController owns its lifetime.
    static func ndsFramebufferImage(from buffer: UnsafeMutablePointer<UInt32>) -> UIImage? {
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(buffer),
            size: ndsFramebufferByteCount,
            releaseData: { _, _, _ in }
        ) else {
            return nil
        }
        return ndsImage(from: provider)
    }

    /// Same picture, but owning its pixels. Use wherever the image outlives the
    /// caller's buffer — caches, singletons, anything handed to another screen.
    /// Costs one 192 KB copy, so never on the per-frame path.
    static func ndsFramebufferImageCopy(from buffer: UnsafeMutablePointer<UInt32>) -> UIImage? {
        let data = Data(bytes: UnsafeRawPointer(buffer), count: ndsFramebufferByteCount)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return ndsImage(from: provider)
    }

    private static let ndsFramebufferByteCount = 256 * 192 * MemoryLayout<UInt32>.size

    private static func ndsImage(from provider: CGDataProvider) -> UIImage? {
        let width = 256
        let height = 192
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
