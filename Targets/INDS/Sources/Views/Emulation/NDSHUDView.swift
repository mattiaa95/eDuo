//
//  NDSHUDView.swift
//  eDuo
//
//  New (loosely inspired by iGBA's small translucent EmuVC overlays — ping /
//  fast-forward labels — but built with modern UIBlurEffect materials instead
//  of flat black-alpha labels). Floating chrome above the controller
//  overlay: a discreet pause
//  button, a screen-layout cycle button, a transient toast, and the
//  loading/error states that replace the old prototype's debug labels.
//

import UIKit

final class NDSHUDView: UIView {

    private var screenLayoutMode: DSScreenLayoutMode = .stacked

    /// Mirrors `DSDualScreenView.reservesControlBand`: false while a gamepad
    /// drives input and the touch overlay is hidden. The arrangements below
    /// change shape with it (an unfolded phone gives the whole lower half to
    /// the touch panel), so the pills must ask with the same value or they
    /// land on the panel.
    private var controlsReserved = true

    var onPauseTapped: (() -> Void)?
    var onCycleLayoutTapped: (() -> Void)?
    var onErrorBackTapped: (() -> Void)?
    /// Fires with the new state on every tap of the Speed pill.
    var onFastForwardTapped: (() -> Void)?

    private let pauseButton = NDSHUDView.makeCircleButton(
        systemName: "pause.fill",
        title: NSLocalizedString("Menu", comment: "HUD button caption: opens the pause menu"))
    private let layoutButton = NDSHUDView.makeCircleButton(
        systemName: DSScreenLayoutMode.stacked.sfSymbolName,
        title: NSLocalizedString("Layout", comment: "HUD button caption: cycles the screen layout"))
    /// Touch users' only route to fast forward — before this it existed solely
    /// as a gamepad hotkey that ships unassigned, so on a phone the feature was
    /// unreachable. A latch that steps through the rates on each tap, not a
    /// hold (see `INDSControllerButtonID.fastForward`): while it is on, the
    /// caption is the rate itself, which is also the only place the rate is
    /// visible during play.
    private let fastForwardButton = NDSHUDView.makeCircleButton(
        systemName: "forward.fill",
        title: NDSHUDView.fastForwardCaption)

    private static let fastForwardCaption = NSLocalizedString(
        "Speed", comment: "HUD button caption: cycles fast forward speed")

    /// nil = off; otherwise the rate currently running.
    private var fastForwardSpeed: Double?

    private let toastLabel = NDSHUDView.makeToastLabel()
    private var toastHideWorkItem: DispatchWorkItem?

    /// Discrete "a controller is driving input right now" indicator — shown
    /// for as long as `NDSRomViewController` reports a gamepad connected
    /// (which is also while the on-screen overlay is hidden), hidden again on
    /// disconnect. Not a toast: no auto-hide timer.
    private let gamepadBadge = NDSHUDView.makeBadge(
        symbol: "gamecontroller.fill", tint: .systemGreen,
        text: NSLocalizedString("Connected", comment: "Gamepad connected HUD badge"))

    /// Discrete "the DS mic is actually listening right now" indicator —
    /// shown for as long as `MelonDSCoreBridge.microphoneActive` reports YES
    /// (polled each display-link tick by `NDSRomViewController`), hidden the
    /// instant the game's mic window closes. Same non-toast shape as
    /// `gamepadBadge`: no auto-hide timer, since "currently being listened
    /// to" should stay visible for exactly as long as it's true. Orange to
    /// match the mic dot iOS itself puts in the status bar.
    private let micBadge = NDSHUDView.makeBadge(
        symbol: "mic.fill", tint: .systemOrange,
        text: NSLocalizedString("Listening", comment: "DS microphone active HUD badge"))

    /// Discrete "a clip is recording right now" indicator — shown for as
    /// long as `NDSClipRecorder.isRecording` is true (mirrored to this view
    /// by `NDSRomViewController` via `onRecordingStateChanged`, since that
    /// state lives outside this view). Same no-auto-hide shape as
    /// `gamepadBadge`/`micBadge`.
    private let recordingBadge = NDSHUDView.makeBadge(
        symbol: "record.circle.fill", tint: .systemRed,
        text: NSLocalizedString("REC", comment: "Clip recording active HUD badge"))

    /// All three persistent badges in one column. They used to be anchored to
    /// the safe area's corners, which is exactly where the controls live:
    /// "Listening" sat on top of the ABXY diamond in portrait and "REC" on
    /// top of L in landscape (device feedback on 1.0(13)).
    ///
    /// Where the column goes depends on the orientation, because the free
    /// space does. In landscape the controls hug the four corners and the top
    /// centre is clear. In portrait the top is the DS's own top screen — the
    /// picture you're actually looking at — so the column drops to the bottom
    /// instead, into the strip under the Menu button, inside the control band
    /// where it covers no game at all (device feedback on 1.0(14)).
    private let badgeStack = UIStackView()

    /// The two placements above, swapped in `layoutSubviews`. The width cap is
    /// portrait-only: that strip is only as wide as the gap between the two
    /// thumb clusters.
    private var badgeTopConstraint: NSLayoutConstraint!
    private var badgeBottomConstraint: NSLayoutConstraint!
    private var badgeCenterXConstraint: NSLayoutConstraint!
    private var badgeWidthConstraint: NSLayoutConstraint!
    /// The toast sits under the badges when they are above it, and takes the
    /// top spot itself when they are not.
    private var toastBelowBadgesConstraint: NSLayoutConstraint!
    private var toastTopConstraint: NSLayoutConstraint!

    private let statusView = NDSStatusOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        pauseButton.accessibilityIdentifier = "hud.pause"
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        layoutButton.addTarget(self, action: #selector(cycleLayoutTapped), for: .touchUpInside)
        // Start invisible — `revealChrome()` fades these in once the game has
        // actually finished loading (see NDSRomViewController.loadCore())
        // instead of popping in ahead of any real content.
        fastForwardButton.accessibilityIdentifier = "hud.fastForward"
        fastForwardButton.addTarget(self, action: #selector(fastForwardTapped), for: .touchUpInside)
        pauseButton.alpha = 0
        layoutButton.alpha = 0
        fastForwardButton.alpha = 0
        addSubview(layoutButton)
        addSubview(pauseButton)
        addSubview(fastForwardButton)
        addSubview(toastLabel)

        badgeStack.axis = .vertical
        badgeStack.alignment = .center
        badgeStack.spacing = 6
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        [recordingBadge, micBadge, gamepadBadge].forEach(badgeStack.addArrangedSubview)
        addSubview(badgeStack)

        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isHidden = true
        statusView.backButton.addTarget(self, action: #selector(errorBackTapped), for: .touchUpInside)
        addSubview(statusView)

        // Menu/Layout are positioned from the controller layout model (see
        // `updatePairPlacement`), not from constraints, so the layout editor
        // can move and hide them like any other button. Everything else here
        // is fixed chrome and stays on Auto Layout.
        NotificationCenter.default.addObserver(self, selector: #selector(controllerLayoutChanged),
                                               name: INDSControllerLayoutManager.layoutDidChangeNotification,
                                               object: nil)

        badgeTopConstraint = badgeStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10)
        badgeBottomConstraint = badgeStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4)
        badgeCenterXConstraint = badgeStack.centerXAnchor.constraint(equalTo: leadingAnchor)
        badgeWidthConstraint = badgeStack.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        // Under the badges rather than at a fixed offset: an empty stack is
        // zero-height, so this is the same spot as before whenever no badge is
        // showing, and the toast steps aside instead of landing on top of one
        // when a badge is.
        toastBelowBadgesConstraint = toastLabel.topAnchor.constraint(equalTo: badgeStack.bottomAnchor, constant: 6)
        toastTopConstraint = toastLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10)

        NSLayoutConstraint.activate([
            badgeCenterXConstraint,

            toastLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),

            statusView.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusView.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusView.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Placement

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePairPlacement()
        updateBadgePlacement()
    }

    /// Tracks which of the two badge placements is currently installed, so
    /// constraints are only touched on an actual orientation change rather
    /// than on every layout pass.
    private var badgesArePortrait: Bool?

    private func updateBadgePlacement() {
        let content = bounds.inset(by: safeAreaInsets)
        guard content.width > 1, content.height > 1 else { return }
        let foldable = DSFoldableLayout.current(in: content.size, mode: screenLayoutMode,
                                                stretch: DSScreenLayoutPreferences.stretchEnabled,
                                                controlsReserved: controlsReserved)
        let console = foldable == nil && controlsReserved
            ? DSConsoleLayout.current(in: content.size, mode: screenLayoutMode,
                                      stretch: DSScreenLayoutPreferences.stretchEnabled) : nil
        // An unfolded foldable in landscape has a control band too — the
        // bottom of the display, either side of the touch panel — so the
        // badges belong in the column between the thumb clusters there as
        // well, not floating in the middle of the game.
        let foldableBand = foldable?.controls != nil
        // The pill row takes the strip under the screens the badge column
        // would use: badges go to the top, as in landscape.
        let isPortrait = foldableBand || (content.height >= content.width && console == nil
                                          && (foldable != nil || gamepadHUDRow(in: content.size) == nil))

        // Portrait: the column between the thumb clusters, where Menu and
        // Layout already live. Landscape: plain centre, nothing is there.
        let bandIdiom = INDSControlBand.effectiveIdiom(for: content.size)
        badgeCenterXConstraint.constant = console != nil ? content.minX + 90 : isPortrait
            ? content.minX + INDSControlBand.hudColumnCenterX(containerWidth: content.width, idiom: bandIdiom)
            : bounds.midX
        badgeWidthConstraint.constant = console != nil ? 160 : INDSControlBand.hudColumnWidth(containerWidth: content.width, idiom: bandIdiom)
        badgeWidthConstraint.isActive = isPortrait || console != nil
        // Console chrome occupies the top row; transient messages go below
        // that row so a save/speed toast never covers the pause button.
        let hasTopChromeRow = console != nil || foldableBand
        toastTopConstraint.constant = hasTopChromeRow ? INDSControllerButtonID.menu.baseSize(for: bandIdiom).height + 20 : 10
        toastBelowBadgesConstraint.isActive = !isPortrait && !hasTopChromeRow
        toastTopConstraint.isActive = isPortrait || hasTopChromeRow

        guard badgesArePortrait != isPortrait else { return }
        badgesArePortrait = isPortrait
        badgeTopConstraint.isActive = !isPortrait
        badgeBottomConstraint.isActive = isPortrait
    }

    @objc private func controllerLayoutChanged() {
        setNeedsLayout()
    }

    /// Places Menu/Layout from their entries in the controller layout — the
    /// same model, editor and persistence as every other button, so the user
    /// can drag them anywhere (or hide them; `NDSRomViewController` keeps a
    /// long-press on the top screen as the way back to the pause menu).
    private func updatePairPlacement() {
        let content = bounds.inset(by: safeAreaInsets)
        guard content.width > 1, content.height > 1 else { return }

        let isPortrait = content.height >= content.width
        // Same three-way choice `NDSControllerView.layout(in:)` makes, in the
        // same order, so Menu/Layout/Speed land in the band beside the thumb
        // controls instead of over the game.
        let foldable = DSFoldableLayout.current(in: content.size, mode: screenLayoutMode,
                                                stretch: DSScreenLayoutPreferences.stretchEnabled,
                                                controlsReserved: controlsReserved)
        let console = foldable == nil && controlsReserved
            ? DSConsoleLayout.current(in: content.size, mode: screenLayoutMode,
                                      stretch: DSScreenLayoutPreferences.stretchEnabled) : nil
        let layout: INDSControllerLayout
        if let custom = INDSControllerLayoutManager.shared.persistedLayout {
            layout = isPortrait ? custom.portrait : custom.landscape
        } else if let foldableControls = foldable?.controls {
            layout = foldableControls
        } else if let console {
            layout = console.controls
        } else if let row = gamepadHUDRow(in: content.size) {
            layout = row
        } else {
            layout = isPortrait
                ? INDSCustomControllerLayout.defaultPortrait(containerSize: content.size)
                : INDSCustomControllerLayout.defaultLandscape(containerSize: content.size)
        }

        // Defaults for THIS content rect, used to rescue buttons a layout saved
        // by an older version doesn't know about (Speed shipped after the
        // editor did). Without this they'd render as the decode-time
        // placeholder: hidden, at dead centre.
        let defaults = isPortrait
            ? INDSCustomControllerLayout.defaultPortrait(containerSize: content.size)
            : INDSCustomControllerLayout.defaultLandscape(containerSize: content.size)

        // Every other visible control, as the overlay will draw it (its
        // global scale included): the room a pill may widen into for its
        // caption is whatever these leave free, see `fitPill`.
        let globalScale = CGFloat(max(0.5, min(2.0, UserDefaults.standard.object(forKey: "eNDSControllerScale") as? Double ?? 1.0)))
        let occupied: [(id: INDSControllerButtonID, frame: CGRect)] = layout.buttons
            .filter(\.isVisible)
            .map { other in
                var frame = other.clampedFrame(in: content.size)
                if !other.id.isHUDChrome {
                    frame = frame.insetBy(dx: -frame.width * (globalScale - 1) / 2,
                                          dy: -frame.height * (globalScale - 1) / 2)
                }
                return (other.id, frame.offsetBy(dx: content.minX, dy: content.minY))
            }

        // Pills are fitted in order and each fitted frame replaces its base
        // frame for the pills after it: two neighbours may otherwise each
        // clear the other's base while growing into each other.
        var fittedFrames: [INDSControllerButtonID: CGRect] = [:]
        for (id, button) in [(INDSControllerButtonID.layout, layoutButton), (.menu, pauseButton),
                             (.fastForward, fastForwardButton)] {
            var resolved = layout.entry(for: id)
            if resolved == nil
                || (resolved!.isVisible == false && resolved!.normalizedX == 0.5 && resolved!.normalizedY == 0.5) {
                resolved = defaults.entry(for: id)
            }
            guard let entry = resolved, entry.isVisible else {
                button.isHidden = true
                continue
            }
            var frame = entry.clampedFrame(in: content.size)
            frame.origin.x += content.minX
            frame.origin.y += content.minY
            let others = occupied.filter { $0.id != id }.map { fittedFrames[$0.id] ?? $0.frame }
            button.frame = fitPill(button, base: frame, content: content, avoiding: others)
            fittedFrames[id] = button.frame
            button.isHidden = false
        }
    }

    /// Gamepad driving, portrait, no foldable/console arrangement: the stacked
    /// screens take the whole height, and the default column of three pills
    /// lands on the touch screen wherever less than its height is left under
    /// them. A row in the leftover strip instead — nil when the column fits.
    private func gamepadHUDRow(in size: CGSize) -> INDSControllerLayout? {
        guard !controlsReserved, size.height >= size.width,
              INDSControllerLayoutManager.shared.persistedLayout == nil,
              DSFoldableLayout.current(in: size, mode: screenLayoutMode, controlsReserved: false) == nil else { return nil }
        let (top, bottom) = DSScreenGeometry.frames(mode: screenLayoutMode, swap: DSScreenLayoutPreferences.swapEnabled,
                                                    stretch: DSScreenLayoutPreferences.stretchEnabled,
                                                    in: CGRect(origin: .zero, size: size))
        guard let top, let bottom else { return nil }
        let column = INDSCustomControllerLayout.defaultPortrait(containerSize: size).buttons
            .filter { $0.isVisible && $0.id.isHUDChrome }
            .map { $0.clampedFrame(in: size) }
        guard column.contains(where: { $0.intersects(top) || $0.intersects(bottom) }) else { return nil }
        return DSFoldableLayout.hudRow(between: top, and: bottom, in: size)
    }

    /// Caption size the pills are authored at (`makeCircleButton`).
    private static let captionPointSize: CGFloat = 9

    /// Caption size last applied per pill. Writing `configuration` relayouts
    /// the button, so only an actual change goes through.
    private var captionPointSizes: [ObjectIdentifier: CGFloat] = [:]

    /// Sizes a pill to its caption. The base width matches the icon plus a
    /// short English word; "Geschwindigkeit" or "Disposição" ran off both
    /// ends of it. The pill grows around its centre, up to twice its base
    /// width, as long as it stays inside the content rect and clear of every
    /// other visible control — in portrait that is the column between the
    /// d-pad and the diamond, in landscape the gap before SELECT/START. Where
    /// it cannot grow enough, the caption shrinks to what fits instead of
    /// overlapping a neighbour.
    private func fitPill(_ button: UIButton, base: CGRect, content: CGRect, avoiding others: [CGRect]) -> CGRect {
        guard let caption = button.configuration?.title, !caption.isEmpty else { return base }
        let insets = button.configuration?.contentInsets ?? .zero
        let horizontal = insets.leading + insets.trailing
        let font = UIFont.systemFont(ofSize: Self.captionPointSize, weight: .semibold)
        let textWidth = ceil((caption as NSString).size(withAttributes: [.font: font]).width)
        let needed = textWidth + horizontal

        var frame = base
        if needed > base.width {
            let grown = base.insetBy(dx: -(min(needed, base.width * 2) - base.width) / 2, dy: 0)
            let clear = content.contains(grown)
                && !others.contains { $0.intersects(grown.insetBy(dx: -2, dy: 0)) }
            if clear { frame = grown }
        }

        let available = frame.width - horizontal
        let pointSize = textWidth > available
            ? max(6, (Self.captionPointSize * available / textWidth * 10).rounded(.down) / 10)
            : Self.captionPointSize
        setCaptionPointSize(pointSize, on: button)
        return frame
    }

    private func setCaptionPointSize(_ pointSize: CGFloat, on button: UIButton) {
        let key = ObjectIdentifier(button)
        guard (captionPointSizes[key] ?? Self.captionPointSize) != pointSize,
              var config = button.configuration else { return }
        captionPointSizes[key] = pointSize
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: pointSize, weight: .semibold)
            return out
        }
        button.configuration = config
    }

    /// Whether the pause button is currently on screen — drives the one-time
    /// "long-press the top screen" hint in `NDSRomViewController`.
    var isPauseButtonVisible: Bool { !pauseButton.isHidden }

    // MARK: - Hit testing — only the chrome itself is interactive

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }

    // MARK: - Actions

    @objc private func pauseTapped() {
        INDSHaptics.light()
        onPauseTapped?()
    }

    @objc private func cycleLayoutTapped() {
        INDSHaptics.light()
        onCycleLayoutTapped?()
    }

    @objc private func fastForwardTapped() {
        INDSHaptics.light()
        // Which rate comes next is not the HUD's call — the owner of the
        // stored setting decides, and tells us back through
        // `setFastForwardSpeed(_:)`.
        onFastForwardTapped?()
    }

    /// Also the entry point for the gamepad hold, so the pill always reflects
    /// the real speed state no matter which input turned it on. nil = off.
    func setFastForwardSpeed(_ speed: Double?) {
        guard fastForwardSpeed != speed else { return }
        fastForwardSpeed = speed
        var config = fastForwardButton.configuration
        config?.baseForegroundColor = speed == nil ? .white : .systemYellow
        config?.title = speed.map(INDSSpeedPreferences.label) ?? Self.fastForwardCaption
        fastForwardButton.configuration = config
        fastForwardButton.accessibilityValue = speed.map(INDSSpeedPreferences.label)
            ?? NSLocalizedString("Off", comment: "Fast forward state")
    }

    @objc private func errorBackTapped() {
        onErrorBackTapped?()
    }

    // MARK: - Public updates

    // Configuration-based buttons ignore `setImage(_:for:)` — mutate the
    // configuration itself.
    func setLayoutIcon(_ mode: DSScreenLayoutMode) {
        screenLayoutMode = mode
        setNeedsLayout()
        layoutButton.configuration?.image = UIImage(systemName: mode.sfSymbolName, withConfiguration: Self.pairSymbolConfig)
    }

    func setPauseIcon(paused: Bool) {
        pauseButton.configuration?.image = UIImage(systemName: paused ? "play.fill" : "pause.fill",
                                                   withConfiguration: Self.pairSymbolConfig)
    }

    /// Shows `text` briefly near the pause button, then fades out. Entry and
    /// exit both combine a short upward translate with the fade instead of a
    /// hard alpha snap — `holdDuration` is how long it stays fully visible
    /// before the exit animation starts (the coach hint below needs longer
    /// than every other caller here, which are all fine with the default).
    func showToast(_ text: String, holdDuration: TimeInterval = 1.1) {
        toastHideWorkItem?.cancel()
        toastLabel.layer.removeAllAnimations()
        toastLabel.text = text
        toastLabel.isHidden = false

        let offscreenTransform = CGAffineTransform(translationX: 0, y: -6)
        toastLabel.alpha = 0
        toastLabel.transform = INDSMotion.reduceMotionEnabled ? .identity : offscreenTransform

        INDSMotion.fadeUIKit(duration: 0.28, options: [.curveEaseOut, .allowUserInteraction]) {
            self.toastLabel.alpha = 1
            self.toastLabel.transform = .identity
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            INDSMotion.fadeUIKit(duration: 0.25, options: [.curveEaseIn, .allowUserInteraction]) {
                self.toastLabel.alpha = 0
                self.toastLabel.transform = INDSMotion.reduceMotionEnabled ? .identity : offscreenTransform
            }
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
    }

    /// Fades the pause/layout chrome in — called once the game has finished
    /// loading (success *or* failure, see `NDSRomViewController.loadCore()`)
    /// instead of showing them ahead of any actual content. Toasts/badges/
    /// status manage their own visibility separately from this.
    func revealChrome() {
        guard pauseButton.alpha < 1 else { return }
        INDSMotion.fadeUIKit(duration: 0.3) {
            self.pauseButton.alpha = 1
            self.layoutButton.alpha = 1
            self.fastForwardButton.alpha = 1
        }
    }

    func showLoading(_ text: String) {
        statusView.showLoading(text)
        statusView.isHidden = false
        bringSubviewToFront(statusView)
    }

    func showError(_ message: String) {
        statusView.showError(message)
        statusView.isHidden = false
        bringSubviewToFront(statusView)
    }

    func hideStatus() {
        statusView.isHidden = true
    }

    /// Shows/hides the discrete "Connected" badge. No auto-hide — stays up
    /// for as long as a gamepad is actually connected.
    func setGamepadConnected(_ connected: Bool) {
        setBadge(gamepadBadge, visible: connected)
        if controlsReserved != !connected {
            controlsReserved = !connected
            setNeedsLayout()
        }
    }

    /// Shows/hides the discrete "Listening" badge. No auto-hide, same as
    /// `setGamepadConnected` above — stays up for exactly as long as
    /// `MelonDSCoreBridge.microphoneActive` reports the mic is actually
    /// capturing.
    func setMicActive(_ active: Bool) {
        setBadge(micBadge, visible: active)
    }

    /// Shows/hides the discrete "REC" badge. No auto-hide, same shape as
    /// `setGamepadConnected`/`setMicActive` — stays up for exactly as long
    /// as a clip is actually recording.
    func setRecordingActive(_ active: Bool) {
        setBadge(recordingBadge, visible: active)
    }

    /// Shared fade for the three persistent status badges above — `isHidden`
    /// only flips to `true` once the fade-out actually finishes, so they
    /// never visually "pop" hidden/visible the way a plain alpha snap did.
    private func setBadge(_ badge: UILabel, visible: Bool) {
        guard visible != (badge.alpha > 0 && !badge.isHidden) else { return }
        if visible {
            badge.isHidden = false
            INDSMotion.fadeUIKit(duration: 0.22) {
                badge.alpha = 1
            }
        } else {
            INDSMotion.fadeUIKit(duration: 0.22) {
                badge.alpha = 0
            } completion: { _ in
                badge.isHidden = true
            }
        }
    }

    // MARK: - Factories

    private static let symbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)

    /// Icon + tiny caption on a blurred pill. `UIButton.Configuration` does
    /// the whole composition — the previous hand-rolled version inserted a
    /// `UIVisualEffectView` as a subview of a `.system` button, and on
    /// device UIKit reordered it OVER the glyph: users saw two unlabeled
    /// dark circles they couldn't decode (v1.0(1) feedback). The caption
    /// exists for the same reason — "Menu"/"Layout" shouldn't need guessing.
    /// Compact symbol size for the Menu/Layout pair — deliberately smaller
    /// than the HUD's other glyphs so a thumb sweeping off the d-pad can't
    /// land on them by accident.
    private static let pairSymbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

    private static func makeCircleButton(systemName: String, title: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName, withConfiguration: pairSymbolConfig)
        config.title = title
        config.imagePlacement = .top
        config.imagePadding = 2
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 4, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: 9, weight: .semibold)
            return out
        }
        var background = UIBackgroundConfiguration.clear()
        background.visualEffect = UIBlurEffect(style: .systemMaterialDark)
        background.cornerRadius = 16
        background.strokeColor = UIColor.white.withAlphaComponent(0.15)
        background.strokeWidth = 1
        config.background = background

        // Frame-based on purpose: these two are placed from the controller
        // layout model in `updatePairPlacement`, not by constraints.
        return UIButton(configuration: config)
    }

    private static let toastFont = UIFontMetrics(forTextStyle: .footnote).scaledFont(
        for: .monospacedSystemFont(ofSize: 12, weight: .semibold),
        maximumPointSize: 16
    )

    private static func makeToastLabel() -> INDSPillLabel {
        let label = INDSPillLabel()
        // Scales with Dynamic Type (capped — this sits in a pill over
        // gameplay, not a page of text) instead of staying pinned at 12pt
        // regardless of the user's text-size setting. Matters most for the
        // first-session coach hint (NDSRomViewController), the longest-lived
        // and most-likely-to-actually-be-read text this label ever shows.
        label.font = toastFont
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .center
        // Two lines, not one: the battery-saver toast is long enough to run
        // off both edges of a phone in portrait, and a pill that reaches the
        // screen edge is a pill with its text cut off.
        label.numberOfLines = 2
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        return label
    }

    /// Symbol + caption on a dark capsule. The badges used to be an emoji
    /// glued to the front of the string ("🎤 Listening") on the same square
    /// pill as the toast, with the text flush against its edges — device
    /// feedback on 1.0(13) called it ugly, and it was: emoji don't take the
    /// label's font weight or its tint, and they render at a different
    /// baseline on every OS version.
    /// Proportional, unlike the toast's monospaced face: a badge is two words
    /// of chrome, and monospacing only earns its keep on the toast's numbers
    /// ("Saved to Slot 2") and long sentences.
    private static let badgeFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
        for: .systemFont(ofSize: 12, weight: .semibold),
        maximumPointSize: 15
    )

    private static func makeBadge(symbol: String, tint: UIColor, text: String) -> INDSPillLabel {
        let label = INDSPillLabel()
        label.font = badgeFont
        label.textColor = .white
        label.isCapsule = true
        label.insets = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 11)
        // The portrait strip is only as wide as the gap between the thumb
        // clusters, so badge captions have to stay short in every language —
        // the Russian "Listening" started as «Микрофон включён» and had to
        // become «Слушаю» to fit. The width cap on the stack is what
        // guarantees a badge can never spill sideways onto the d-pad or the
        // ABXY diamond; these two only soften what a too-long one looks like.
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7

        let attachment = NSTextAttachment()
        let glyphConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        attachment.image = UIImage(systemName: symbol, withConfiguration: glyphConfig)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        if let size = attachment.image?.size {
            // Centre the glyph on the text's cap height instead of sitting it
            // on the baseline, where it hangs visibly low.
            attachment.bounds = CGRect(x: 0, y: ((badgeFont.capHeight - size.height) / 2).rounded(),
                                       width: size.width, height: size.height)
        }
        let composed = NSMutableAttributedString(attachment: attachment)
        // attributedText ignores the label's own font/textColor, so the text
        // run has to carry them itself.
        composed.append(NSAttributedString(string: " " + text, attributes: [
            .font: badgeFont,
            .foregroundColor: UIColor.white
        ]))
        label.attributedText = composed
        label.accessibilityLabel = text

        label.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return label
    }
}

/// A `UILabel` that draws on a padded pill. Plain `UILabel` has no content
/// insets at all, so text sits flush against the rounded background — most
/// of why the HUD's badges looked cheap next to the rest of the chrome.
final class INDSPillLabel: UILabel {

    var insets = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)

    /// Fully rounded ends (badges) instead of the toast's softer square pill.
    var isCapsule = false {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerCurve = .continuous
        layer.cornerRadius = 8
        clipsToBounds = true
        isHidden = true
        alpha = 0
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isCapsule { layer.cornerRadius = bounds.height / 2 }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    /// Overriding this (and not `intrinsicContentSize`) is what makes the
    /// padding real: UILabel derives its intrinsic size, and its multi-line
    /// wrapping width, from this one method. Overriding both double-counts
    /// the insets and leaves the pill visibly too wide for its text.
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left,
                                           bottom: -insets.bottom, right: -insets.right))
    }
}

// MARK: - Status / Error overlay

/// Replaces the old prototype's debug `statusLabel` with a small card used
/// both for the "loading ROM" spinner state and for a load-failure message
/// with a way back to the library (the emulation screen hides its nav bar,
/// so this is the only way back if `loadROM` throws).
private final class NDSStatusOverlayView: UIView {

    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    let backButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        spinner.color = .white
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.isHidden = true

        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        backButton.setTitle(NSLocalizedString("Back to Library", comment: ""), for: .normal)
        backButton.tintColor = .white
        backButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [spinner, iconView, titleLabel, backButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),

            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -26)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func showLoading(_ text: String) {
        spinner.isHidden = false
        spinner.startAnimating()
        iconView.isHidden = true
        backButton.isHidden = true
        titleLabel.text = text
    }

    func showError(_ message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        iconView.isHidden = false
        backButton.isHidden = false
        titleLabel.text = message
    }
}
