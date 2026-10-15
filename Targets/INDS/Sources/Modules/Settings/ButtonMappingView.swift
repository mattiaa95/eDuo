//
//  ButtonMappingView.swift
//  eDuo
//
//  External-controller remapping, ported from iGBA: the controller is DRAWN.
//
//  Two ways in, same result:
//  - Button first: press a button on the real controller (it lights up and
//    sinks on the drawing) or tap it on the drawing, then pick what it does.
//  - Action first: tap an action ("Fast forward (on/off)") and press the
//    button that should do it. Pressing nothing for a while says why: iOS
//    keeps some buttons (Home, Share) for itself on some controllers.
//
//  Whatever is pressed also lights up the action it triggers in the list, so
//  "what does this button do?" is answered by pressing it.
//
//  Live presses use pressedChangedHandler, a separate slot from the
//  valueChangedHandler the gameplay input path installs — both keep working,
//  and ours are removed on disappear. Which physical element a key means is
//  resolved by INDSControllerElements, the same call the gameplay path uses,
//  so what lights up here is exactly what the game reads.
//

import SwiftUI
import GameController

struct ButtonMappingView: View {

    @State private var mapping: [String: Int] = INDSControllerMappingStore.activeMapping()
    @State private var controller: GCController? = nil
    @State private var pressed: Set<String> = []
    @State private var selectedKey: String? = nil
    /// Action waiting for a button press.
    @State private var capture: INDSMappingTarget? = nil
    @State private var captureToken = 0
    @State private var captureTimedOut = false
    @State private var notice: Notice? = nil
    @State private var confirmResetOne = false
    @State private var confirmResetAll = false

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private struct Notice: Equatable {
        let message: String
        let undo: [String: Int]
        let orphan: INDSMappingTarget?
    }

    private static let captureSeconds: Double = 8

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            if verticalSizeClass == .compact {
                // Landscape phone: the drawing stays put on the left while the
                // list scrolls on the right.
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            headerCard
                            diagramCard
                        }
                        .padding(12)
                    }
                    .frame(width: geo.size.width * 0.46)
                    ScrollView {
                        VStack(spacing: 14) { detailCards }
                            .padding(12)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        headerCard
                        diagramCard
                        detailCards
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(NSLocalizedString("Button Mapping", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
        .onAppear {
            mapping = INDSControllerMappingStore.activeMapping()
            refreshController()
        }
        .onDisappear {
            uninstallPressHandlers()
            capture = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            refreshController()
            mapping = INDSControllerMappingStore.activeMapping() // profile may have activated
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            refreshController()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidBecomeCurrent)) { _ in
            refreshController()
        }
        .confirmationDialog(NSLocalizedString("Reset this controller?", comment: "Mapping reset confirmation"),
                            isPresented: $confirmResetOne, titleVisibility: .visible) {
            Button(NSLocalizedString("Reset to Defaults", comment: ""), role: .destructive) {
                remember(NSLocalizedString("Mapping reset to defaults", comment: "Mapping notice"))
                INDSControllerMappingStore.resetToDefaults(controller: controller)
                mapping = INDSControllerMappingStore.activeMapping()
            }
        }
        .confirmationDialog(NSLocalizedString("Reset every controller?", comment: "Mapping reset-all confirmation"),
                            isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button(NSLocalizedString("Reset all controllers", comment: "Mapping reset-all button"), role: .destructive) {
                INDSControllerMappingStore.resetAllControllers()
                mapping = INDSControllerMappingStore.activeMapping()
                notice = nil
            }
        } message: {
            Text(NSLocalizedString("Forgets the mapping saved for every controller you have connected.", comment: "Mapping reset-all explanation"))
        }
    }

    @ViewBuilder
    private var detailCards: some View {
        if let notice {
            noticeCard(notice)
        }
        if let selectedKey {
            selectedCard(selectedKey)
        }
        conflictsCard
        actionsCard(title: NSLocalizedString("DS buttons", comment: "Mapping section: Nintendo DS buttons"),
                    icon: "gamecontroller.fill",
                    targets: INDSMappingTarget.consoleOrder)
        actionsCard(title: NSLocalizedString("Emulator actions", comment: "Mapping section: fast forward, menu…"),
                    icon: "bolt.fill",
                    targets: emulatorTargets)
        resetCard
        diagnosticsCard
    }

    private var emulatorTargets: [INDSMappingTarget] { INDSMappingTarget.emulatorOrder }

    // MARK: - Header & drawing

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: controller != nil ? "gamecontroller.fill" : "gamecontroller")
                .font(.title2)
                .foregroundColor(controller != nil ? .green : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller?.vendorName ?? NSLocalizedString("No controller connected", comment: "External controller status"))
                    .font(.subheadline.weight(.semibold))
                Text(controller != nil
                     ? NSLocalizedString("Saved for this controller model. It comes back whenever it reconnects.", comment: "Mapping header: profile per controller")
                     : NSLocalizedString("Connect it over Bluetooth or USB-C. You can set it up now; it applies when it connects.", comment: "Mapping header: no controller"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(card)
    }

    private var diagramCard: some View {
        VStack(spacing: 12) {
            ControllerDiagramView(style: ControllerStyle.of(controller),
                                  controller: controller,
                                  mapping: mapping,
                                  pressed: pressed,
                                  selected: selectedKey,
                                  capturing: capture != nil) { key in
                tapped(key)
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)

            if let capture {
                captureBanner(capture)
            } else {
                Text(controller != nil
                     ? NSLocalizedString("Press any button: it lights up here and in the list. Tap a button to change what it does.", comment: "Mapping hint with controller")
                     : NSLocalizedString("Tap a button on the drawing to choose what it does.", comment: "Mapping hint without controller"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(card)
        .animation(.easeOut(duration: 0.2), value: capture)
    }

    private func captureBanner(_ target: INDSMappingTarget) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: target.symbol)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller != nil
                         ? NSLocalizedString("Press the button for", comment: "Mapping capture: waiting for a press; followed by the action name")
                         : NSLocalizedString("Tap the button for", comment: "Mapping capture without controller; followed by the action name"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(target.displayName)
                        .font(.headline)
                }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { cancelCapture() }
                    .buttonStyle(.bordered)
            }
            if captureTimedOut {
                Label(NSLocalizedString("Nothing arrived from the controller. Some buttons (Home, Share) are kept by iOS on some controllers and never reach apps — try another one.", comment: "Mapping capture timed out"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }

    // MARK: - Selected button

    private func selectedCard(_ key: String) -> some View {
        let glyph = ControllerGlyphs.glyph(for: key, on: controller)
        let current = target(of: key)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: glyph.symbol)
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(glyph.name)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                        Text(current.displayName)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    withAnimation { selectedKey = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Close", comment: ""))
            }

            if let note = note(for: key, current: current) {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            choiceGrid(title: NSLocalizedString("DS buttons", comment: "Mapping section: Nintendo DS buttons"),
                       targets: INDSMappingTarget.consoleOrder, key: key, current: current)
            choiceGrid(title: NSLocalizedString("Emulator actions", comment: "Mapping section: fast forward, menu…"),
                       targets: INDSMappingTarget.emulatorOrder + [.none], key: key, current: current)
        }
        .padding(14)
        .background(card)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5))
    }

    private func choiceGrid(title: String, targets: [INDSMappingTarget], key: String, current: INDSMappingTarget) -> some View {
        // Console names are one word; emulator actions need the room.
        let minimum: CGFloat = targets.contains(.fastForward) ? 150 : 96
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8)], spacing: 8) {
                ForEach(targets) { target in
                    let isOn = target == current
                    Button {
                        assign(target, to: key)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: target.symbol)
                                .font(.footnote)
                            Text(target.displayName)
                                .font(.footnote)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundColor(isOn ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isOn ? Color.accentColor : Color(UIColor.tertiarySystemFill))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    private func note(for key: String, current: INDSMappingTarget) -> String? {
        switch key {
        case "Home", "Share":
            return NSLocalizedString("iOS uses this button for itself (Games app, screenshots). Giving it a job here turns that off while eDuo is open. Some controllers never send it to apps.", comment: "Mapping note for Home/Share")
        case "Menu" where INDSMappingLogic.menuEscapeApplies(mapping):
            return NSLocalizedString("Hold it for a moment and it still opens the pause menu.", comment: "Mapping note: remapped Menu button")
        case let direction where INDSPhysicalKey.directions.contains(direction) && !current.isDirection:
            return ControllerGlyphs.hasStick(controller)
                ? NSLocalizedString("The left stick still moves you around.", comment: "Mapping note: D-pad direction remapped, stick available")
                : nil
        default:
            return nil
        }
    }

    // MARK: - Notices & conflicts

    private func noticeCard(_ notice: Notice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(notice.message, systemImage: notice.orphan == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundColor(notice.orphan == nil ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(NSLocalizedString("Undo", comment: "")) {
                    INDSControllerMappingStore.setMapping(notice.undo, controller: controller)
                    mapping = INDSControllerMappingStore.activeMapping()
                    withAnimation { self.notice = nil }
                }
                .buttonStyle(.bordered)
                if let orphan = notice.orphan {
                    Button(String(format: NSLocalizedString("Give %@ a button", comment: "Mapping: assign the action left without a button"), orphan.displayName)) {
                        startCapture(orphan)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button {
                    withAnimation { self.notice = nil }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Close", comment: ""))
            }
        }
        .padding(14)
        .background(card)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var conflictsCard: some View {
        let missing = INDSMappingLogic.unreachableEssentials(mapping, hasStick: ControllerGlyphs.hasStick(controller))
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(NSLocalizedString("No button does this", comment: "Mapping conflicts header"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.orange)
                Text(NSLocalizedString("Most games need these. Give each one a button.", comment: "Mapping conflicts explanation"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(missing) { target in
                    HStack {
                        Image(systemName: target.symbol)
                            .frame(width: 24)
                        Text(target.displayName)
                        Spacer()
                        Button(NSLocalizedString("Assign", comment: "Mapping: start assigning a button to an action")) {
                            startCapture(target)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .background(card)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.6), lineWidth: 1.5))
        }
    }

    // MARK: - Actions list

    private func actionsCard(title: String, icon: String, targets: [INDSMappingTarget]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(targets) { target in
                actionRow(target)
                if target != targets.last {
                    Divider().padding(.leading, 52)
                }
            }
            if targets.contains(.turboToggle) {
                Divider().padding(.leading, 52)
                NavigationLink(destination: Form { INDSTurboSettingsSection() }
                    .navigationTitle(NSLocalizedString("Rapid fire (turbo)", comment: "Rapid fire settings title"))
                    .navigationBarTitleDisplayMode(.inline)) {
                    HStack(spacing: 12) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(.orange)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Rapid fire settings", comment: "Mapping: link to rapid fire settings"))
                                .foregroundColor(.primary)
                            Text(turboSummary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(.bottom, 6)
        .background(card)
    }

    private func actionRow(_ target: INDSMappingTarget) -> some View {
        let keys = INDSMappingLogic.keys(for: target, in: mapping)
            .filter { ControllerGlyphs.exists($0, on: controller) }
        let live = keys.contains { pressed.contains($0) }
        let waiting = capture == target
        return Button {
            if waiting { cancelCapture() } else { startCapture(target) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: target.symbol)
                    .foregroundColor(target.isEmulatorAction ? .orange : .accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName)
                        .foregroundColor(.primary)
                    if let detail = target.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if waiting {
                    Text(NSLocalizedString("Press a button…", comment: "Mapping row while waiting for a press"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                } else if keys.isEmpty {
                    Text("—")
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(keys, id: \.self) { key in
                            Image(systemName: ControllerGlyphs.glyph(for: key, on: controller).symbol)
                                .font(.title3)
                                .foregroundColor(pressed.contains(key) ? .accentColor : .secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(keys.map { ControllerGlyphs.glyph(for: $0, on: controller).name }.joined(separator: ", "))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                (live || waiting ? Color.accentColor.opacity(0.14) : Color.clear)
                    .animation(.easeOut(duration: 0.12), value: live)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(NSLocalizedString("Then press the controller button that should do it.", comment: "Mapping row accessibility hint"))
    }

    // MARK: - Reset & diagnostics

    private var resetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                confirmResetOne = true
            } label: {
                Label(controller != nil
                      ? NSLocalizedString("Reset this controller", comment: "Mapping: reset current controller")
                      : NSLocalizedString("Reset to Defaults", comment: ""),
                      systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button(role: .destructive) {
                confirmResetAll = true
            } label: {
                Label(NSLocalizedString("Reset all controllers", comment: "Mapping reset-all button"),
                      systemImage: "arrow.counterclockwise.circle")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    @ViewBuilder
    private var diagnosticsCard: some View {
        // A pad whose buttons do nothing is otherwise a dead end for support:
        // this is the one place a tester can read back what iOS handed the app.
        if let controller {
            DisclosureGroup(NSLocalizedString("What eDuo detects", comment: "Controller diagnostics disclosure")) {
                Text(detected(controller))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .font(.caption)
            .padding(14)
            .background(card)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
    }

    // MARK: - Mapping

    /// «A · B · 15/s» or «Off»: what the turbo link says under it.
    private var turboSummary: String {
        let names = INDSTurboPreferences.eligible.filter(INDSTurboPreferences.isTurbo).map(INDSTurboPreferences.displayName)
        guard !names.isEmpty else { return NSLocalizedString("Off", comment: "Rapid fire summary when no button has rapid fire") }
        return (names + [String(format: NSLocalizedString("%d/s", comment: "Rapid fire presses per second, short"), INDSTurboPreferences.rateHz)])
            .joined(separator: " · ")
    }

    private func target(of key: String) -> INDSMappingTarget {
        INDSMappingTarget(rawValue: mapping[key] ?? INDSMappingTarget.none.rawValue) ?? .none
    }

    private func tapped(_ key: String) {
        if let capture {
            assign(capture, to: key)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedKey = selectedKey == key ? nil : key
            }
        }
    }

    private func assign(_ target: INDSMappingTarget, to key: String) {
        let before = INDSControllerMappingStore.activeMapping()
        let orphan = INDSControllerMappingStore.assign(target, toPhysical: key, controller: controller)
        let after = INDSControllerMappingStore.activeMapping()
        mapping = after
        capture = nil
        captureToken += 1
        captureTimedOut = false
        selectedKey = key
        guard before != after else { return }

        let name = ControllerGlyphs.glyph(for: key, on: controller).name
        var message = String(format: NSLocalizedString("%@ now does: %@", comment: "Mapping notice: physical button, action"),
                             name, target.displayName)
        if let orphan {
            message += "\n" + String(format: NSLocalizedString("%@ has no button any more.", comment: "Mapping notice: action left without a button"),
                                     orphan.displayName)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            notice = Notice(message: message, undo: before, orphan: orphan)
        }
        UINotificationFeedbackGenerator().notificationOccurred(orphan == nil ? .success : .warning)
    }

    private func remember(_ message: String) {
        notice = Notice(message: message, undo: mapping, orphan: nil)
    }

    fileprivate func startCapture(_ target: INDSMappingTarget) {
        captureToken += 1
        let token = captureToken
        captureTimedOut = false
        withAnimation { capture = target }
        UISelectionFeedbackGenerator().selectionChanged()
        guard controller != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureSeconds) {
            if captureToken == token && capture != nil {
                withAnimation { captureTimedOut = true }
            }
        }
    }

    private func cancelCapture() {
        captureToken += 1
        withAnimation {
            capture = nil
            captureTimedOut = false
        }
    }

    // MARK: - Controller

    private func refreshController() {
        uninstallPressHandlers()
        controller = GCController.current ?? GCController.controllers().first
        pressed = []
        installPressHandlers()
    }

    private func detected(_ controller: GCController) -> String {
        let names = INDSControllerElements.detectedNames(on: controller)
        let profile = controller.extendedGamepad != nil ? "extended gamepad" : "generic profile"
        return """
        \(controller.productCategory) · \(profile)
        \(names.isEmpty ? "no inputs reported" : names.joined(separator: ", "))
        """
    }

    private func installPressHandlers() {
        guard let controller else { return }
        for key in INDSPhysicalKey.all {
            ControllerGlyphs.element(for: key, on: controller)?.pressedChangedHandler = { _, _, isPressed in
                DispatchQueue.main.async { physical(key, isPressed: isPressed) }
            }
        }
        // While this screen is open, Home/Share/Menu have to reach it or they
        // could never be captured. Put back on the way out.
        for key in ["Home", "Share", "Menu"] {
            ControllerGlyphs.element(for: key, on: controller)?.preferredSystemGestureState = .disabled
        }
    }

    private func uninstallPressHandlers() {
        guard let controller else { return }
        for key in INDSPhysicalKey.all {
            ControllerGlyphs.element(for: key, on: controller)?.pressedChangedHandler = nil
        }
        INDSGamepadManager.applySystemGestures(on: controller)
    }

    fileprivate func physical(_ key: String, isPressed: Bool) {
        if isPressed {
            pressed.insert(key)
            if let capture {
                assign(capture, to: key)
            } else {
                withAnimation(.easeOut(duration: 0.15)) { selectedKey = key }
            }
        } else {
            pressed.remove(key)
        }
    }
}
