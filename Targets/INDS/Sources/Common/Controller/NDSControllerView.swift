//
//  NDSControllerView.swift
//  eDuo
//
//  Ported and adapted from iGBA's CustomControllerView.swift.
//  On-screen controller overlay that reads button positions from
//  `INDSControllerLayoutManager` and drives `MelonDSCoreBridge.setButton:pressed:`
//  through a delegate. Adaptations vs. iGBA:
//   - Direct `INDSButton`/`Set<INDSButton>` typing instead of NSNumber-boxed
//     legacy GBA raw ints (eDuo has no ObjC-interop legacy code to share with).
//   - No turbo, A+B combo, macro slots, or menu button — DS has X/Y instead,
//     and pause lives in a separate floating HUD button (see `NDSHUDView`).
//   - `hitTest` only claims points that land on a visible button/joystick, so
//     touches elsewhere fall through to the Touch screen underneath this
//     full-bleed overlay — the key trick that lets an iGBA-style overlay
//     coexist with a real stylus screen (GBA never needed this).
//

import UIKit

protocol NDSControllerViewDelegate: AnyObject {
    func controllerView(_ view: NDSControllerView, setButton button: INDSButton, pressed: Bool)
}

final class NDSControllerView: UIView {

    weak var delegate: NDSControllerViewDelegate?

    var screenLayoutMode: DSScreenLayoutMode = .stacked {
        didSet { if oldValue != screenLayoutMode { setNeedsLayout() } }
    }

    // MARK: - Configuration

    /// Controller opacity applied to all button visuals. Floor of 0.15: a
    /// persisted 0 would make every button invisible but still tappable, with
    /// no way back short of reinstalling (the didSet re-clamp fixes that).
    var skinOpacity: CGFloat = 0.55 {
        didSet {
            if skinOpacity < 0.15 { skinOpacity = 0.15 }
            updateOpacity()
        }
    }

    /// Global size multiplier from Settings ("eNDSControllerScale", default
    /// 1.0), applied on top of each button's own per-entry `scale` from the
    /// layout editor. Same "read once at setup(), takes effect next time you
    /// open a game" contract as `skinOpacity` — see `ControlsSettingsView`.
    private var globalScale: CGFloat = 1.0

    // MARK: - Subviews / State

    private var buttonViews: [INDSControllerButtonID: UIView] = [:]
    private var buttonFrames: [INDSControllerButtonID: CGRect] = [:]
    private var joystickView: INDSVirtualJoystickView?
    private var touchButtons: [UITouch: Set<INDSButton>] = [:]
    /// What the delegate currently believes is down from touches: the union
    /// of every live touch's set. Diffed in `syncHeldButtons`, so a button
    /// held by two fingers stays down until the last one lifts.
    private var heldTouchButtons: Set<INDSButton> = []
    private var currentJoystickDirections: Set<INDSButton> = []

    /// Last layout actually laid out, kept so touch handling reads exactly the
    /// entries the on-screen frames were built from.
    private var currentLayout = INDSControllerLayout(buttons: [])

    /// The content rect buttons are positioned in — the view's bounds minus
    /// the safe area, i.e. the same rect `DSDualScreenView` lays the DS
    /// screens out in, so the reserved control band lines up on both sides.
    private var contentRect: CGRect {
        bounds.inset(by: safeAreaInsets)
    }

    /// The user's saved layout if they have one, otherwise defaults built for
    /// this exact container. Defaults are resolved per-geometry on purpose:
    /// the control band is a fixed number of *points*, so its normalized
    /// position differs on every device (see `INDSControlBand`).
    private func layout(in containerSize: CGSize) -> INDSControllerLayout {
        let isPortrait = containerSize.height >= containerSize.width
        if let custom = INDSControllerLayoutManager.shared.persistedLayout {
            return isPortrait ? custom.portrait : custom.landscape
        }
        let defaults = {
            isPortrait
                ? INDSCustomControllerLayout.defaultPortrait(containerSize: containerSize)
                : INDSCustomControllerLayout.defaultLandscape(containerSize: containerSize)
        }
        // An unfolded folding iPhone decides before the classic DS layout
        // does, and a nil `controls` there means "the default arrangement is
        // already right for this half" — portrait, where the reserved band is
        // nowhere near the fold.
        if let foldable = DSFoldableLayout.current(
            in: containerSize, mode: screenLayoutMode,
            stretch: DSScreenLayoutPreferences.stretchEnabled,
            // Same crease the screens use, or the touch panel and the thumb
            // clusters drift apart.
            fold: DSFoldableLayout.fold(for: self, content: contentRect,
                                        vertical: containerSize.height >= containerSize.width)) {
            return foldable.controls ?? defaults()
        }
        if let console = DSConsoleLayout.current(in: containerSize, mode: screenLayoutMode,
                                                  stretch: DSScreenLayoutPreferences.stretchEnabled) {
            return console.controls
        }
        return defaults()
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let savedOpacity = UserDefaults.standard.object(forKey: "eNDSControllerOpacity") as? Double
        skinOpacity = CGFloat(savedOpacity ?? 0.55)

        let savedScale = UserDefaults.standard.object(forKey: "eNDSControllerScale") as? Double
        globalScale = CGFloat(max(0.5, min(2.0, savedScale ?? 1.0)))

        NotificationCenter.default.addObserver(self, selector: #selector(layoutSettingChanged),
                                                name: INDSControllerLayoutManager.layoutDidChangeNotification, object: nil)
        rebuildLayout()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil { releaseAllActiveInputs() }
        super.willMove(toSuperview: newSuperview)
    }

    @objc private func layoutSettingChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildLayout()
        }
    }

    // MARK: - Persisted opacity

    /// Persists and applies a new global opacity, clamped to the 0.15 floor.
    func setPersistedOpacity(_ value: CGFloat) {
        let clamped = max(0.15, min(1.0, value))
        UserDefaults.standard.set(Double(clamped), forKey: "eNDSControllerOpacity")
        skinOpacity = clamped
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        updateButtonFrames()
    }

    private func rebuildLayout() {
        let size = contentRect.size
        guard size.width > 1, size.height > 1 else {
            // No geometry yet (this runs once from `setup()`): there is
            // nothing to resolve the defaults against. `layoutSubviews` calls
            // back in with a real content rect and builds then.
            releaseAllActiveInputs()
            setNeedsLayout()
            return
        }
        rebuildSubviews(for: layout(in: size))
        setNeedsLayout()
        updateButtonFrames()
    }

    /// Tears down and recreates the button views. Also drops any in-flight
    /// touch: the frames those presses were matched against are about to stop
    /// existing, and a half-released press would stick a button down.
    private func rebuildSubviews(for layout: INDSControllerLayout) {
        releaseAllActiveInputs()
        buttonViews.values.forEach { $0.removeFromSuperview() }
        buttonViews.removeAll()
        buttonFrames.removeAll()
        joystickView?.removeFromSuperview()
        joystickView = nil
        currentLayout = layout

        for entry in layout.buttons {
            // Menu/Layout live in the same model so the editor can move and
            // hide them, but `NDSHUDView` owns their views — it keeps them
            // alive when a gamepad hides this overlay entirely.
            guard entry.isVisible, !entry.id.isHUDChrome else { continue }

            if entry.id == .dpad && layout.directionalInputType == .joystick {
                let joy = INDSVirtualJoystickView(frame: .zero)
                joy.baseAlpha = skinOpacity * 0.5
                joy.thumbAlpha = skinOpacity
                joy.onDirectionsChanged = { [weak self] directions in
                    self?.handleJoystickDirections(directions)
                }
                addSubview(joy)
                joystickView = joy
                buttonViews[.dpad] = joy
            } else if entry.id == .dpad {
                let dpad = INDSDPadShapeView(frame: .zero)
                dpad.alpha = skinOpacity
                dpad.isUserInteractionEnabled = false
                dpad.onAccessibilityDirection = { [weak self] button in
                    self?.momentaryPress(button, duration: 0.15)
                }
                addSubview(dpad)
                buttonViews[.dpad] = dpad
            } else {
                let style = entry.style ?? .defaultStyle(for: entry.id)
                let view = INDSStyledButtonView(buttonID: entry.id, style: style)
                view.alpha = skinOpacity
                view.isUserInteractionEnabled = false
                addSubview(view)
                buttonViews[entry.id] = view
            }

            // VoiceOver: this overlay resolves multi-touch itself and its button
            // subviews have interaction disabled — right for a gamepad, but it
            // left every control unreachable and unnamed. Naming them makes them
            // navigable; `accessibilityActivate` below is what makes them
            // pressable, since VoiceOver never delivers raw touches here.
            if let view = buttonViews[entry.id] {
                view.isAccessibilityElement = true
                view.accessibilityLabel = entry.id.accessibilityName
                view.accessibilityTraits = .button
                if let styled = view as? INDSStyledButtonView {
                    styled.onAccessibilityActivate = { [weak self] in
                        self?.momentaryPress(entry.id)
                    }
                }
            }
        }

    }

    /// VoiceOver "activate" (double tap) for a single button: press and release
    /// after one frame. Not a substitute for playing — an action game is not
    /// playable one tap at a time — but menus, START/SELECT and confirmations
    /// are, and the alternative was a screen VoiceOver could not touch at all.
    /// Someone who wants to play normally turns on Direct Touch on the DS
    /// screen (see `DSDualScreenView`).
    private func momentaryPress(_ id: INDSControllerButtonID) {
        guard let button = id.indsButton else { return }
        momentaryPress(button, duration: 0.1)
    }

    /// Same press-and-release for a single engine button — the d-pad's
    /// VoiceOver custom actions (Up/Down/Left/Right) come through here.
    private func momentaryPress(_ button: INDSButton, duration: TimeInterval) {
        delegate?.controllerView(self, setButton: button, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            self.delegate?.controllerView(self, setButton: button, pressed: false)
        }
    }

    private func updateButtonFrames() {
        // Position buttons relative to the safe-area-inset content rect so
        // defaults never land under a notch, Dynamic Island or the home
        // indicator; layout math itself stays untouched by this offset.
        let content = contentRect
        guard content.width > 1, content.height > 1 else {
            DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
            return
        }

        // Re-resolve every pass: with no saved layout the defaults are a
        // function of this container, so a size change (rotation, Split View,
        // first real bounds after `setup()`) can legitimately move buttons.
        let layout = self.layout(in: content.size)
        let missingViews = buttonViews.isEmpty && layout.buttons.contains(where: \.isVisible)
        if layout != currentLayout || missingViews {
            rebuildSubviews(for: layout)
        }

        for entry in layout.buttons {
            guard entry.isVisible, let view = buttonViews[entry.id] else { continue }

            var frame = scaledFrame(for: entry, in: content.size)
            frame.origin.x += content.minX
            frame.origin.y += content.minY

            view.frame = frame
            buttonFrames[entry.id] = frame

            if let styled = view as? INDSStyledButtonView {
                styled.updateForSize(frame.size)
            }
        }

        #if DEBUG
        // Once the layout settles, not now: while it rotates, the iPhone Duo
        // reports its 84 pt system rail on BOTH sides (folded, landscape →
        // portrait: 298 pt wide for the whole animation, then 382). Only an
        // overlap that survives the layout is a bug.
        overlapCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in self?.assertDefaultLayoutHasNoOverlaps() }
        overlapCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
        #endif
    }

    #if DEBUG
    private var overlapCheck: DispatchWorkItem?

    /// v1.0(8) shipped defaults where the d-pad overlapped L by 16-32pt on
    /// every phone, so a thumb on the d-pad fired the shoulder too. That class
    /// of bug is what this catches, against the real clamped, globally-scaled
    /// frames, on every debug layout pass — and only for the defaults, since a
    /// hand-placed layout may overlap on purpose and that's the user's call.
    ///
    /// The four face buttons are exempt: their diamond is deliberately tight
    /// (see `INDSControlBand.faceSpread`) and `buttonsForTouch` resolves that
    /// overlap by nearest center rather than pressing both.
    private func assertDefaultLayoutHasNoOverlaps() {
        guard INDSControllerLayoutManager.shared.persistedLayout == nil else { return }
        let faceCluster: Set<INDSControllerButtonID> = [.a, .b, .x, .y]
        let frames = buttonFrames
            .filter { currentLayout.entry(for: $0.key)?.isVisible == true }
            .sorted { $0.key.rawValue < $1.key.rawValue }
        for (index, lhs) in frames.enumerated() {
            for rhs in frames.dropFirst(index + 1) where lhs.value.intersects(rhs.value) {
                if faceCluster.contains(lhs.key), faceCluster.contains(rhs.key) { continue }
                assertionFailure("Default layout overlap: \(lhs.key.rawValue) x \(rhs.key.rawValue) "
                                 + "-> \(lhs.value.intersection(rhs.value)) in \(contentRect.size)")
            }
        }
    }
    #endif

    /// Applies `globalScale` on top of the entry's own clamped frame,
    /// expanding around its center and re-clamping inside `containerSize` —
    /// the same clamp-after-scale shape `INDSButtonLayoutEntry.clampedFrame`
    /// itself uses. Kept local to this view rather than added to the shared
    /// layout model: this multiplier is a Settings-only concept the model
    /// (and the layout editor, which has its own per-button scale) doesn't
    /// need to know about.
    private func scaledFrame(for entry: INDSButtonLayoutEntry, in containerSize: CGSize) -> CGRect {
        let base = entry.clampedFrame(in: containerSize)
        guard globalScale != 1.0 else { return base }
        let width = base.width * globalScale
        let height = base.height * globalScale
        var frame = CGRect(x: base.midX - width / 2, y: base.midY - height / 2, width: width, height: height)
        frame.origin.x = max(0, min(containerSize.width - frame.width, frame.origin.x))
        frame.origin.y = max(0, min(containerSize.height - frame.height, frame.origin.y))
        return frame
    }

    private func updateOpacity() {
        for (id, view) in buttonViews {
            if id == .dpad, let joy = view as? INDSVirtualJoystickView {
                joy.baseAlpha = skinOpacity * 0.5
                joy.thumbAlpha = skinOpacity
            } else {
                view.alpha = skinOpacity
            }
        }
    }

    // MARK: - Input Cleanup

    /// Releases all actively held inputs. Must be called before rebuild,
    /// removal, or orientation change to prevent stuck buttons.
    func releaseAllActiveInputs() {
        if !currentJoystickDirections.isEmpty {
            for button in currentJoystickDirections {
                delegate?.controllerView(self, setButton: button, pressed: false)
            }
            currentJoystickDirections = []
        }

        touchButtons.removeAll()
        syncHeldButtons()

        joystickView?.cancelTracking()
    }

    // MARK: - Joystick Directions Callback

    private func handleJoystickDirections(_ rawDirections: Set<Int>) {
        let newDirections = Set(rawDirections.compactMap { INDSButton(rawValue: $0) })

        let released = currentJoystickDirections.subtracting(newDirections)
        let pressed = newDirections.subtracting(currentJoystickDirections)
        currentJoystickDirections = newDirections

        for button in released { delegate?.controllerView(self, setButton: button, pressed: false) }
        if !pressed.isEmpty {
            INDSHaptics.light()
            for button in pressed { delegate?.controllerView(self, setButton: button, pressed: true) }
        }
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressButtons(for: touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateButtons(for: touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseButtons(for: touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseButtons(for: touches)
    }

    private func pressButtons(for touches: Set<UITouch>) {
        for touch in touches {
            if let joystickView {
                let joyPoint = touch.location(in: joystickView)
                if joystickView.point(inside: joyPoint, with: nil) { continue }
            }
            touchButtons[touch] = buttonsForTouch(touch)
        }
        syncHeldButtons()
    }

    private func updateButtons(for touches: Set<UITouch>) {
        for touch in touches {
            if let joystickView {
                let joyPoint = touch.location(in: joystickView)
                if joystickView.point(inside: joyPoint, with: nil) {
                    touchButtons[touch] = nil
                    continue
                }
            }
            touchButtons[touch] = buttonsForTouch(touch)
        }
        syncHeldButtons()
    }

    private func releaseButtons(for touches: Set<UITouch>) {
        for touch in touches { touchButtons[touch] = nil }
        syncHeldButtons()
    }

    /// The one place touch bookkeeping turns into delegate calls. Diffing the
    /// union of every live touch against what was last reported means a
    /// button is released only when no finger holds it any more — a per-touch
    /// diff released it as soon as either of two fingers on it lifted.
    private func syncHeldButtons() {
        var held: Set<INDSButton> = []
        for buttons in touchButtons.values { held.formUnion(buttons) }

        let released = heldTouchButtons.subtracting(held)
        let pressed = held.subtracting(heldTouchButtons)
        heldTouchButtons = held

        for button in released { delegate?.controllerView(self, setButton: button, pressed: false) }
        if !pressed.isEmpty {
            INDSHaptics.light()
            for button in pressed { delegate?.controllerView(self, setButton: button, pressed: true) }
        }
    }

    /// Maps a touch point to the set of engine buttons it activates.
    ///
    /// One touch resolves to exactly ONE control: whichever visible button
    /// contains the point with the nearest center. Unioning every frame that
    /// contains the point (what this did until 1.0(11)) meant any overlap —
    /// and the ABXY diamond is deliberately tight now, like a real DS, so its
    /// diagonal neighbours do overlap — pressed two buttons at once from a
    /// single thumb. Pressing A *and* B on purpose still works: that is two
    /// touches, and each is resolved on its own.
    private func buttonsForTouch(_ touch: UITouch) -> Set<INDSButton> {
        let point = touch.location(in: self)
        let layout = currentLayout

        var winner: (entry: INDSButtonLayoutEntry, frame: CGRect, distance: CGFloat)?
        for entry in layout.buttons {
            guard entry.isVisible, let frame = buttonFrames[entry.id], frame.contains(point) else { continue }
            if entry.id == .dpad && layout.directionalInputType == .joystick { continue }
            guard entry.id == .dpad || entry.id.indsButton != nil else { continue }

            let distance = hypot(point.x - frame.midX, point.y - frame.midY)
            if winner == nil || distance < winner!.distance {
                winner = (entry, frame, distance)
            }
        }

        guard let winner else { return [] }
        if winner.entry.id == .dpad {
            return dpadButtonsForPoint(point, inRect: winner.frame)
        }
        return winner.entry.id.indsButton.map { [$0] } ?? []
    }

    /// D-pad 9-zone detection: 4 edges + 4 diagonals + dead center.
    private func dpadButtonsForPoint(_ point: CGPoint, inRect rect: CGRect) -> Set<INDSButton> {
        let up: INDSButton = .up
        let down: INDSButton = .down
        let left: INDSButton = .left
        let right: INDSButton = .right

        let topRect    = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 3)
        let bottomRect = CGRect(x: rect.minX, y: rect.minY + rect.height * 2 / 3, width: rect.width, height: rect.height / 3)
        let leftRect   = CGRect(x: rect.minX, y: rect.minY, width: rect.width / 3, height: rect.height)
        let rightRect  = CGRect(x: rect.minX + rect.width * 2 / 3, y: rect.minY, width: rect.width / 3, height: rect.height)

        let topLeft     = topRect.intersection(leftRect)
        let topRight    = topRect.intersection(rightRect)
        let bottomLeft  = bottomRect.intersection(leftRect)
        let bottomRight = bottomRect.intersection(rightRect)

        if topLeft.contains(point)     { return [up, left] }
        if topRight.contains(point)    { return [up, right] }
        if bottomLeft.contains(point)  { return [down, left] }
        if bottomRight.contains(point) { return [down, right] }
        if topRect.contains(point)     { return [up] }
        if leftRect.contains(point)    { return [left] }
        if bottomRect.contains(point)  { return [down] }
        if rightRect.contains(point)   { return [right] }

        return []
    }

    // MARK: - Hit Testing (let non-button touches fall through to the screen)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }

        // The joystick tracks its own touches: it only ever sees them when it
        // is the hit-test view. Answering `self` here handed them to
        // `pressButtons`, which skips anything inside the ring — the stick
        // drew but never moved.
        if let joystickView, joystickView.point(inside: convert(point, to: joystickView), with: event) {
            return joystickView
        }

        let layout = currentLayout
        for entry in layout.buttons {
            guard entry.isVisible, let frame = buttonFrames[entry.id], frame.contains(point) else { continue }
            return self
        }
        return nil
    }
}
