//
//  NDSPauseMenuView.swift
//  eDuo
//
//  Ported and adapted from iGBA's PauseMenuView.swift: same
//  visual language (grouped-background rows with icon + title + subtitle,
//  inline slider cards, prominent Resume button, drag-to-dismiss-resumes
//  sheet) applied to eDuo's action set — no link cable, macros or TAS;
//  adds DS-only concerns (screen layout, save-state slots with timestamps,
//  haptics toggle) plus cheats, a display filter and clip recording, ported
//  from iGBA separately (Cheats/AREngine, Display Filter, Record Clip below).
//

import SwiftUI

/// One-shot actions the pause menu can trigger. A plain Swift enum (unlike
/// iGBA's `@objc enum PauseMenuAction`) since nothing here needs to cross an
/// Objective-C boundary — lets slot actions carry an associated `Int`.
enum NDSPauseMenuAction {
    case reset
    case quitToLibrary
    case saveToSlot(Int)
    case loadFromSlot(Int) // -1 == auto-save
    /// Put back the battery save as it was before this session's first state
    /// load. Only offered when a snapshot exists (see `INDSSaveBackup`).
    case recoverCartridgeSave
    /// ~10 s back through the in-memory history (`MelonDSCoreBridge.rewindTenSeconds`).
    case rewind
}

// MARK: - Speed slider (0.5x … 3x, all free)
//
// The ladder is `INDSSpeedPreferences.speeds`, the same one the GBA app
// offers, so the steps match for anyone who plays both. It used to stop at
// 2x because a PRO-gated 4x was a paid promise the interpreter could not
// keep on a phone; nothing above is sold now, so the higher steps are just
// "go as fast as this device manages" and a slow one simply falls short.
// Fast Forward is a separate, faster ladder (`fastForwardSpeeds`), reached
// from the on-screen Speed button and a controller's hold — see
// `NDSRomViewController.setFastForwardHold`.

private struct NDSSpeedSliderView: View {
    // Seeded in init, not onAppear: seeding an already-live @State goes
    // through `.onChange(of: speedIndex)` below and reported the current
    // speed back as a user change on every open of the menu.
    @State private var speedIndex: Double
    let speeds: [Double]
    let onSpeedChanged: (Double) -> Void

    init(currentSpeed: Double, speeds: [Double], onSpeedChanged: @escaping (Double) -> Void) {
        _speedIndex = State(initialValue: Double(speeds.firstIndex(of: currentSpeed) ?? 0))
        self.speeds = speeds
        self.onSpeedChanged = onSpeedChanged
    }

    private func label(for speed: Double) -> String { INDSSpeedPreferences.label(speed) }

    var body: some View {
        VStack(spacing: 8) {
            currentSpeedRow
            speedSlider
            speedTickRow
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Speed", comment: ""))
    }

    // Split out of `body` — a single large `ViewBuilder` expression combining
    // this row + the slider + the gated tick row hit the type-checker's
    // "failed to produce diagnostic for expression" internal error; each
    // piece type-checks fine as its own subview.

    private var currentSpeedRow: some View {
        HStack {
            Image(systemName: "speedometer")
                .font(.body.weight(.medium))
                .foregroundColor(.accentColor)
            Text(NSLocalizedString("Speed", comment: ""))
                .font(.body)
            Spacer()
            Text(label(for: speeds[max(0, min(speeds.count - 1, Int(speedIndex)))]))
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var speedSlider: some View {
        Slider(value: $speedIndex, in: 0...Double(speeds.count - 1), step: 1) { Text("Speed") }
            .onChange(of: speedIndex) { _, newValue in
                let idx = max(0, min(speeds.count - 1, Int(newValue)))
                INDSHaptics.light()
                onSpeedChanged(speeds[idx])
            }
    }

    private var speedTickRow: some View {
        HStack {
            ForEach(Array(speeds.enumerated()), id: \.offset) { idx, speed in
                if idx > 0 { Spacer() }
                speedTick(speed)
            }
        }
        .padding(.horizontal, 4)
    }

    private func speedTick(_ speed: Double) -> some View {
        VStack(spacing: 2) {
            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            HStack(spacing: 2) {
                Text(label(for: speed)).font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Screen layout card

private struct NDSScreenLayoutCard: View {
    @Binding var mode: DSScreenLayoutMode
    @Binding var swapEnabled: Bool
    @Binding var stretchEnabled: Bool
    let onCycle: () -> DSScreenLayoutMode
    let onToggleSwap: (Bool) -> Void
    let onToggleStretch: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: mode.sfSymbolName)
                    .font(.body.weight(.medium))
                    .frame(width: 24)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Screen Layout", comment: ""))
                        .font(.body)
                    Text(mode.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    INDSHaptics.light()
                    mode = onCycle()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.semibold))
                        .padding(8)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Cycle Screen Layout", comment: ""))
            }

            Toggle(isOn: Binding(
                get: { swapEnabled },
                set: { newValue in
                    swapEnabled = newValue
                    INDSHaptics.light()
                    onToggleSwap(newValue)
                }
            )) {
                Label(NSLocalizedString("Swap Screens", comment: ""), systemImage: "arrow.up.arrow.down")
                    .font(.subheadline)
            }

            Toggle(isOn: Binding(
                get: { stretchEnabled },
                set: { newValue in
                    stretchEnabled = newValue
                    INDSHaptics.light()
                    onToggleStretch(newValue)
                }
            )) {
                Label(NSLocalizedString("Fill Screen", comment: ""), systemImage: "rectangle.expand.vertical")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Display filter card (smooth/crisp free, scanlines PRO-gated)

private struct NDSDisplayFilterCard: View {
    @Binding var filter: NDSDisplayFilter
    let onFilterChanged: (NDSDisplayFilter) -> Void

    @ObservedObject private var entitlements = EntitlementManager.shared
    @State private var pendingOffer: ProGateOffer?

    private var isScanlinesEntitled: Bool {
        entitlements.hasPro || INDSHoneymoon.isActive
    }

    private func isLocked(_ option: NDSDisplayFilter) -> Bool {
        option.requiresEntitlement && !isScanlinesEntitled
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: filter.sfSymbolName)
                    .font(.body.weight(.medium))
                    .frame(width: 24)
                    .foregroundColor(.accentColor)
                Text(NSLocalizedString("Display Filter", comment: ""))
                    .font(.body)
                Spacer()
                Text(filter.displayName)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            // Pills stretch to the tallest one so a two-line label (ru
            // "Сканирующие линии") doesn't leave the row ragged.
            HStack(spacing: 8) {
                ForEach(NDSDisplayFilter.allCases, id: \.self) { option in
                    filterPill(option)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .proGateAlert(offer: $pendingOffer)
    }

    private func filterPill(_ option: NDSDisplayFilter) -> some View {
        let selected = filter == option
        let locked = isLocked(option)

        return Button {
            INDSHaptics.light()
            if locked {
                pendingOffer = ProGateOffer(
                    title: NSLocalizedString("Scanlines is PRO", comment: "Display filter gate alert title"),
                    message: NSLocalizedString("Smooth and Crisp are always free. Go PRO to unlock the Scanlines filter.", comment: "Display filter gate alert message")
                )
            } else {
                filter = option
                onFilterChanged(option)
            }
        } label: {
            VStack(spacing: 3) {
                Text(option.displayName)
                    .font(.caption.weight(selected ? .semibold : .regular))
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
            .foregroundColor(selected ? .accentColor : .secondary)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Audio card

private struct NDSAudioCard: View {
    @Binding var volume: Double
    @State private var preMuteVolume: Double = 0.7
    let onVolumeChanged: (Double) -> Void

    private var isMuted: Bool { volume <= 0.0001 }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body.weight(.medium))
                    .frame(width: 24)
                    .foregroundColor(.accentColor)
                Text(NSLocalizedString("Audio", comment: ""))
                    .font(.body)
                Spacer()
                Toggle(NSLocalizedString("Mute", comment: ""), isOn: Binding(
                    get: { isMuted },
                    set: { muted in
                        if muted {
                            preMuteVolume = volume > 0 ? volume : preMuteVolume
                            volume = 0
                        } else {
                            volume = preMuteVolume > 0 ? preMuteVolume : 0.7
                        }
                        onVolumeChanged(volume)
                    }
                ))
                .labelsHidden()
            }
            Slider(value: $volume, in: 0...1) { editing in
                if !editing { onVolumeChanged(volume) }
            }
            .disabled(isMuted)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - PauseMenuView

struct NDSPauseMenuView: View {
    let romTitle: String
    let romBaseName: String
    let currentSpeed: Double
    let saveSlots: [NDSSaveStateSlotInfo]
    let loadSlots: [NDSSaveStateSlotInfo]
    let initialVolume: Double
    let initialLayoutMode: DSScreenLayoutMode
    let initialSwapEnabled: Bool
    let initialStretchEnabled: Bool
    let canRewind: Bool
    let initialDisplayFilter: NDSDisplayFilter
    @ObservedObject var clipRecorder: NDSClipRecorder

    let onAction: (NDSPauseMenuAction) -> Void
    let onResume: () -> Void
    let onSpeedChanged: (Double) -> Void
    let onVolumeChanged: (Double) -> Void
    let onCycleLayout: () -> DSScreenLayoutMode
    let onToggleSwap: (Bool) -> Void
    let onToggleStretch: (Bool) -> Void
    let onCheatsChanged: () -> Void
    let onDisplayFilterChanged: (NDSDisplayFilter) -> Void
    let onToggleClipRecording: () -> Void

    @State private var volume: Double = 0.7
    @State private var layoutMode: DSScreenLayoutMode = .stacked
    @State private var swapEnabled = false
    @State private var stretchEnabled = false
    @State private var displayFilter: NDSDisplayFilter = .smooth
    @State private var hapticsEnabled = INDSHaptics.isEnabled

    @State private var showSaveSheet = false
    @State private var showLoadSheet = false
    @State private var showCheatsSheet = false
    @State private var showResetConfirmation = false
    @State private var showRecoverSaveConfirmation = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isIPad: Bool { horizontalSizeClass == .regular }

    private static let speeds: [Double] = INDSSpeedPreferences.speeds

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            VStack(spacing: 2) {
                Text(NSLocalizedString("Paused", comment: ""))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text(romTitle)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    menuRow(icon: "square.and.arrow.down", title: NSLocalizedString("Save State", comment: "")) {
                        showSaveSheet = true
                    }
                    menuRow(icon: "square.and.arrow.up", title: NSLocalizedString("Load State", comment: "")) {
                        showLoadSheet = true
                    }
                    if canRewind {
                        menuRow(icon: "backward.end.alt.fill", title: NSLocalizedString("Rewind", comment: "")) {
                            onAction(.rewind)
                        }
                    }
                    menuRow(icon: "arrow.counterclockwise", title: NSLocalizedString("Reset", comment: ""), destructive: true) {
                        showResetConfirmation = true
                    }
                    menuRow(icon: "wand.and.stars", title: NSLocalizedString("Cheats", comment: "")) {
                        showCheatsSheet = true
                    }
                    if clipRecorder.isAvailable {
                        clipRecordingRow
                    }

                    NDSSpeedSliderView(currentSpeed: currentSpeed, speeds: Self.speeds, onSpeedChanged: onSpeedChanged)

                    NDSScreenLayoutCard(mode: $layoutMode, swapEnabled: $swapEnabled, stretchEnabled: $stretchEnabled,
                                       onCycle: onCycleLayout, onToggleSwap: onToggleSwap, onToggleStretch: onToggleStretch)

                    NDSDisplayFilterCard(filter: $displayFilter, onFilterChanged: onDisplayFilterChanged)

                    NDSAudioCard(volume: $volume, onVolumeChanged: onVolumeChanged)

                    Toggle(isOn: Binding(
                        get: { hapticsEnabled },
                        set: { newValue in
                            hapticsEnabled = newValue
                            INDSHaptics.isEnabled = newValue
                            if newValue { INDSHaptics.light() }
                        }
                    )) {
                        HStack(spacing: 14) {
                            Image(systemName: "hand.tap.fill")
                                .font(.body.weight(.medium))
                                .frame(width: 24)
                                .foregroundColor(.accentColor)
                            Text(NSLocalizedString("Haptics", comment: ""))
                                .font(.body)
                        }
                    }
                    .padding(.vertical, 13)
                    .padding(.horizontal, 16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(10)

                    // Only when this session actually snapshotted a battery save
                    // — i.e. a state was loaded and could have overwritten it.
                    if INDSSaveBackup.hasBackup(baseName: romBaseName) {
                        menuRow(icon: "arrow.uturn.backward.circle",
                                title: NSLocalizedString("Recover Cartridge Save", comment: "Pause menu: restore the battery save from before this session's state load")) {
                            showRecoverSaveConfirmation = true
                        }
                        .padding(.top, 6)
                    }

                    menuRow(icon: "rectangle.portrait.and.arrow.right", title: NSLocalizedString("Quit to Library", comment: ""), destructive: true) {
                        onAction(.quitToLibrary)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: isIPad ? 540 : .infinity)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
            }
            .alert(NSLocalizedString("Reset Console?", comment: ""), isPresented: $showResetConfirmation) {
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
                Button(NSLocalizedString("Reset", comment: ""), role: .destructive) { onAction(.reset) }
            } message: {
                Text(NSLocalizedString("The game will restart from the beginning. An autosave is kept, but progress since your last save state will be lost.", comment: ""))
            }
            .alert(NSLocalizedString("Recover Cartridge Save?", comment: ""), isPresented: $showRecoverSaveConfirmation) {
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
                Button(NSLocalizedString("Recover", comment: ""), role: .destructive) { onAction(.recoverCartridgeSave) }
            } message: {
                let explanation = NSLocalizedString("Puts back the game's own save file as it was before a save state was loaded this session, then restarts the game. Use this if loading a state rolled back your in-game progress.", comment: "Recover cartridge save explanation")
                // The timestamp is what tells the player *which* save they are
                // about to go back to — the `.bak` can predate this session.
                if let date = INDSSaveBackup.backupDate(baseName: romBaseName) {
                    let stamp = date.formatted(date: .abbreviated, time: .shortened)
                    Text(explanation + "\n\n" + String(format: NSLocalizedString("Backup from %@", comment: "Recover cartridge save: when the backup was taken"), stamp))
                } else {
                    Text(explanation)
                }
            }

            Button {
                INDSHaptics.light()
                onResume()
            } label: {
                Label {
                    Text(NSLocalizedString("Resume", comment: "")).fontWeight(.semibold)
                } icon: {
                    Image(systemName: "play.fill")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .pressableScale()
            .frame(maxWidth: isIPad ? 540 : .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityHint(NSLocalizedString("Resumes the game", comment: ""))
        }
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            volume = initialVolume
            layoutMode = initialLayoutMode
            swapEnabled = initialSwapEnabled
            stretchEnabled = initialStretchEnabled
            displayFilter = initialDisplayFilter
        }
        .sheet(isPresented: $showSaveSheet) {
            NDSSaveStateSlotsView(mode: .save, slots: saveSlots, onSelectSlot: { slot in
                onAction(.saveToSlot(slot))
            }, romBaseName: romBaseName)
        }
        .sheet(isPresented: $showLoadSheet) {
            NDSSaveStateSlotsView(mode: .load, slots: loadSlots, onSelectSlot: { slot in
                onAction(.loadFromSlot(slot))
            }, romBaseName: romBaseName)
        }
        .sheet(isPresented: $showCheatsSheet) {
            NDSCheatsView(romBaseName: romBaseName, onCheatsChanged: onCheatsChanged)
        }
        .alert(NSLocalizedString("Couldn't Start Recording", comment: "Clip recording error alert title"), isPresented: Binding(
            get: { clipRecorder.lastErrorMessage != nil },
            set: { if !$0 { clipRecorder.lastErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        } message: {
            Text(clipRecorder.lastErrorMessage ?? "")
        }
    }

    /// "Record Clip" / "Stop Recording" — same row shape as `menuRow` below,
    /// duplicated rather than parameterizing that helper further: this is
    /// the only row whose leading glyph swaps between an SF Symbol and a
    /// plain red dot depending on state.
    private var clipRecordingRow: some View {
        let recording = clipRecorder.isRecording
        return Button {
            INDSHaptics.light()
            onToggleClipRecording()
        } label: {
            HStack(spacing: 14) {
                if recording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .frame(width: 24, alignment: .center)
                } else {
                    Image(systemName: "record.circle")
                        .font(.body.weight(.medium))
                        .frame(width: 24, alignment: .center)
                        .foregroundColor(.accentColor)
                }
                Text(recording ? NSLocalizedString("Stop Recording", comment: "") : NSLocalizedString("Record Clip", comment: ""))
                    .font(.body)
                    .foregroundColor(recording ? .red : .primary)
                Spacer()
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recording ? NSLocalizedString("Stop Recording", comment: "") : NSLocalizedString("Record Clip", comment: ""))
    }

    @ViewBuilder
    private func menuRow(icon: String, title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            INDSHaptics.light()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .frame(width: 24, alignment: .center)
                    .foregroundColor(destructive ? .red : .accentColor)
                Text(title)
                    .font(.body)
                    .foregroundColor(destructive ? .red : .primary)
                Spacer()
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
