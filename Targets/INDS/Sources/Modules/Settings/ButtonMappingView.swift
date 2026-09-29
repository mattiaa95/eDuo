//
//  ButtonMappingView.swift
//  eDuo
//
//  Settings → Controls → Controller Mapping. Adapted from iGBA's
//  ButtonMappingView.swift but organized the other way round:
//  one row per DS BUTTON / APP ACTION (18 possible targets), each captured by
//  tapping the row and then pressing the physical controller button that
//  should trigger it — rather than iGBA's one-row-per-physical-button picker.
//  DS has more targets (12 buttons + 6 app actions) than a standard pad has
//  remappable physical inputs (9), so browsing "what triggers Quick Save?"
//  and pressing a button to set it reads better here than hunting across 9
//  physical rows for wherever an app action might currently be hiding.
//
//  Which physical button a capture sees is resolved by INDSControllerElements,
//  the same call the gameplay path uses — including for pads iOS does not give
//  an extendedGamepad (an 8BitDo FlipPad over USB-C, for one), which used to
//  read as "no controller connected" here and could not be remapped at all.
//
//  Capture only runs while a controller is connected (it needs a live button
//  press to capture) — no controller connected shows a dedicated empty state
//  instead of the row list, unlike iGBA's version (which stays editable with
//  no hardware present, since its picker-based UI doesn't need a live press).
//
//  `pressedChangedHandler` is a separate handler slot from the
//  `valueChangedHandler` `INDSGamepadManager` installs during gameplay — both
//  can coexist — but in practice this screen is only reachable from the ROM
//  library (Settings sheet), never while a game/INDSGamepadManager instance
//  is alive, so there's no real contention either way.
//

import SwiftUI
import GameController

struct ButtonMappingView: View {

    @State private var mapping: [String: Int] = INDSControllerMappingStore.activeMapping()
    @State private var controller: GCController? = GCController.controllers().first
    @State private var capturingTarget: INDSMappingTarget?
    @State private var confirmingReset = false

    private var rowTargets: [INDSMappingTarget] {
        INDSMappingTarget.pickerOrder.filter { $0 != .none }
    }

    var body: some View {
        Form {
            Section {
                statusRow
            }

            if controller != nil {
                Section {
                    ForEach(rowTargets) { target in
                        row(for: target)
                    }
                } header: {
                    Text("Button / Action → Controller Button")
                } footer: {
                    Text("Tap a row, then press the controller button you want to trigger it. The D-pad, left stick, and system Menu button always control movement and pause, and can't be reassigned.")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        endCapture()
                        confirmingReset = true
                    }
                    .confirmationDialog("Reset controller mapping?", isPresented: $confirmingReset, titleVisibility: .visible) {
                        Button("Reset to Defaults", role: .destructive) {
                            INDSControllerMappingStore.resetToDefaults(controller: controller)
                            mapping = INDSControllerMappingStore.activeMapping()
                        }
                    } message: {
                        Text("Your custom buttons for this controller will be lost.")
                    }
                } footer: {
                    Text("This mapping is remembered for this controller model and restored whenever it reconnects.")
                }
            } else {
                Section {
                    emptyState
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Controller Mapping")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
        .onAppear { refreshController() }
        .onDisappear { endCapture() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshController() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshController() }
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: controller != nil ? "gamecontroller.fill" : "gamecontroller")
                .font(.title2)
                .foregroundColor(controller != nil ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller?.vendorName ?? NSLocalizedString("No controller connected", comment: "Controller mapping status row: no gamepad paired"))
                    .font(.subheadline.weight(.semibold))
                if let controller {
                    Text("Tap a row below, then press the button you want to assign.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // A pad whose buttons do nothing is otherwise a dead end
                    // for support: this is the one place a tester can read back
                    // what iOS actually handed the app.
                    DisclosureGroup("What eDuo detects") {
                        Text(INDSControllerElements.detectedNames(on: controller).joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Connect a controller", systemImage: "gamecontroller")
        } description: {
            Text("Connect a game controller over Bluetooth or USB-C, then come back here to customize its buttons.")
        }
    }

    private func row(for target: INDSMappingTarget) -> some View {
        let key = physicalKey(for: target)
        let isCapturing = capturingTarget == target

        return HStack {
            Text(target.displayName)
            Spacer()
            if isCapturing {
                Text("Press a button…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
            } else if let key {
                Text(physicalDisplayName(key))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Button {
                    clear(target)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .accessibilityLabel(NSLocalizedString("Clear Mapping", comment: "Removes the controller button assigned to this row"))
            } else {
                Text("Unassigned")
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(isCapturing ? Color.accentColor.opacity(0.12) : nil)
        .onTapGesture { beginCapture(for: target) }
    }

    // MARK: - Capture

    private func beginCapture(for target: INDSMappingTarget) {
        guard let controller else { return }
        capturingTarget = target
        for (key, button) in INDSControllerElements.buttons(on: controller) {
            button.pressedChangedHandler = { _, _, pressed in
                guard pressed else { return }
                DispatchQueue.main.async {
                    complete(capturedKey: key, target: target)
                }
            }
        }
    }

    private func complete(capturedKey: String, target: INDSMappingTarget) {
        guard capturingTarget == target else { return } // stale callback (Reset/disappear/disconnect already ran)
        assign(physicalKey: capturedKey, to: target)
        endCapture()
    }

    private func endCapture() {
        capturingTarget = nil
        guard let controller else { return }
        for (_, button) in INDSControllerElements.buttons(on: controller) {
            button.pressedChangedHandler = nil
        }
    }

    // MARK: - Store read/write

    /// Assigning `physicalKey` to `target` first clears any OTHER physical
    /// input already pointing at `target`, so every row keeps showing at
    /// most one physical button (the store itself is physical-key-indexed
    /// and would otherwise happily leave two buttons triggering the same
    /// target — harmless at runtime, but confusing to read back in this UI).
    private func assign(physicalKey: String, to target: INDSMappingTarget) {
        for key in INDSControllerMappingStore.remappablePhysicalInputs
        where key != physicalKey && INDSControllerMappingStore.target(forPhysical: key) == target {
            INDSControllerMappingStore.setTarget(.none, forPhysical: key, controller: controller)
        }
        INDSControllerMappingStore.setTarget(target, forPhysical: physicalKey, controller: controller)
        mapping = INDSControllerMappingStore.activeMapping()
    }

    private func clear(_ target: INDSMappingTarget) {
        guard let key = physicalKey(for: target) else { return }
        INDSControllerMappingStore.setTarget(.none, forPhysical: key, controller: controller)
        mapping = INDSControllerMappingStore.activeMapping()
    }

    /// Physical keys are storage identifiers (`INDSControllerElements`);
    /// the letters read the same everywhere, the one word does not.
    private func physicalDisplayName(_ key: String) -> String {
        key == "Options" ? NSLocalizedString("Options", comment: "Physical gamepad button") : key
    }

    /// Reverse lookup against the locally-cached `mapping` snapshot (not a
    /// fresh store read) so SwiftUI's dependency tracking on `@State
    /// mapping` is what drives the row refresh after every write above.
    private func physicalKey(for target: INDSMappingTarget) -> String? {
        INDSControllerMappingStore.remappablePhysicalInputs.first { mapping[$0] == target.rawValue }
    }

    private func refreshController() {
        let next = GCController.controllers().first
        if next !== controller {
            endCapture()
            controller = next
        }
        mapping = INDSControllerMappingStore.activeMapping()
    }
}
