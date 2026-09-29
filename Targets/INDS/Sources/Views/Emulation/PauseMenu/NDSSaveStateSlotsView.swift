//
//  NDSSaveStateSlotsView.swift
//  eDuo
//
//  New (no direct iGBA equivalent — iGBA's save-state UI is a separate legacy
//  screen not in scope for this port). Small slot picker presented as a
//  nested sheet from `NDSPauseMenuView` for both "Save State" and
//  "Load State" — 4 numbered slots, plus an Auto-Save row when loading.
//

import SwiftUI

/// One save-state slot as shown to the user. `slot == -1` marks the
/// dedicated auto-save (distinct file from the 4 numbered slots).
struct NDSSaveStateSlotInfo: Identifiable, Equatable {
    let slot: Int
    let modifiedDate: Date?
    var id: Int { slot }
    var isAuto: Bool { slot < 0 }
    var isEmpty: Bool { modifiedDate == nil }
}

struct NDSSaveStateSlotsView: View {
    enum Mode {
        case save
        case load

        var title: String {
            switch self {
            case .save: return NSLocalizedString("Save State", comment: "")
            case .load: return NSLocalizedString("Load State", comment: "")
            }
        }
    }

    let mode: Mode
    let slots: [NDSSaveStateSlotInfo]
    let onSelectSlot: (Int) -> Void
    /// Base name of the running ROM — needed to delete a slot's file. Optional
    /// so the existing previews/call sites that only pick a slot still compile.
    var romBaseName: String? = nil

    /// Mirrors `slots` but survives a deletion, so the sheet can update itself
    /// instead of staying stale until it is dismissed and reopened.
    @State private var liveSlots: [NDSSaveStateSlotInfo] = []
    @State private var slotPendingDeletion: NDSSaveStateSlotInfo?
    /// Saving over a used slot used to wipe the previous state with no warning.
    @State private var slotPendingOverwrite: NDSSaveStateSlotInfo?
    /// Loaded once when the sheet opens: these are 256×192 PNGs on disk and
    /// re-reading them on every `body` pass buys nothing.
    @State private var thumbs: [Int: UIImage] = [:]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var entitlements = EntitlementManager.shared
    @State private var pendingOffer: ProGateOffer?
    @State private var pendingSlot: Int?

    /// Slot 1 (index 0) and the auto-save (index -1) are always free; slots
    /// 2-4 need PRO (or the first-48h honeymoon). Only gates *saving* — loading a
    /// slot that already has data in it (e.g. saved while PRO was active) is
    /// never blocked, so a lapsed subscription can't cost the user access to
    /// their own save. An empty slot in Load mode is already disabled below
    /// regardless, so there's nothing to gate there.
    private func isLocked(_ slot: NDSSaveStateSlotInfo) -> Bool {
        guard mode == .save, slot.slot >= 1 else { return false }
        return !entitlements.hasPro && !INDSHoneymoon.isActive
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Text(mode.title)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(liveSlots) { slot in
                        slotRow(slot)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .proGateAlert(offer: $pendingOffer)
        // Without this `liveSlots` stays [] and the sheet comes up empty:
        // neither saving nor loading. And copying `slots` verbatim will not do
        // either: those arrays were computed when the pause menu was
        // presented, so saving into a slot and reopening the sheet WITHOUT
        // leaving pause would show it as "Empty" — Save would skip the
        // overwrite confirmation and Load would come up disabled, as if the
        // save had failed. Every row is refreshed against disk on open.
        .onAppear {
            if let base = romBaseName {
                liveSlots = slots.map {
                    NDSSaveStateSlotInfo(slot: $0.slot,
                                         modifiedDate: NDSSaveStatePaths.modifiedDate(baseName: base, slot: $0.slot))
                }
                thumbs = Dictionary(uniqueKeysWithValues: liveSlots.compactMap { slot in
                    NDSSaveStatePaths.thumbnail(baseName: base, slot: slot.slot).map { (slot.slot, $0) }
                })
            } else {
                liveSlots = slots
            }
        }
        .confirmationDialog(
            NSLocalizedString("Overwrite this slot?", comment: "Save-state overwrite confirmation title"),
            isPresented: Binding(get: { slotPendingOverwrite != nil },
                                 set: { if !$0 { slotPendingOverwrite = nil } }),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("Overwrite", comment: "Save-state overwrite confirmation action"),
                   role: .destructive) {
                if let slot = slotPendingOverwrite { onSelectSlot(slot.slot) }
                slotPendingOverwrite = nil
                dismiss()
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                slotPendingOverwrite = nil
            }
        } message: {
            Text(NSLocalizedString("The save state already in this slot will be replaced. The game's own save file is not affected.",
                                   comment: "Save-state overwrite confirmation message"))
        }
        .confirmationDialog(
            NSLocalizedString("Delete this save state?", comment: "Save-state deletion confirmation title"),
            isPresented: Binding(get: { slotPendingDeletion != nil },
                                 set: { if !$0 { slotPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("Delete Save State", comment: "Context menu action on a save-state slot"),
                   role: .destructive) {
                deletePendingSlot()
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                slotPendingDeletion = nil
            }
        } message: {
            Text(NSLocalizedString("This save state will be gone for good. The game's own save file is not affected.",
                                   comment: "Save-state deletion confirmation message"))
        }
    }

    /// Deletes the file and leaves the row as "Empty": the sheet always shows
    /// the same slots, and removing the row would throw the numbering off.
    private func deletePendingSlot() {
        defer { slotPendingDeletion = nil }
        guard let target = slotPendingDeletion, let base = romBaseName,
              NDSSaveStatePaths.deleteSlot(baseName: base, slot: target.slot),
              let i = liveSlots.firstIndex(where: { $0.slot == target.slot }) else { return }
        liveSlots[i] = NDSSaveStateSlotInfo(slot: target.slot, modifiedDate: nil)
        thumbs[target.slot] = nil
    }

    /// The save state's own thumbnail when there is one; otherwise (empty
    /// slot, or saved by a build older than thumbnails) the previous icon.
    @ViewBuilder
    private func slotArtwork(_ slot: NDSSaveStateSlotInfo) -> some View {
        if let image = thumbs[slot.slot] {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)          // pixel art: nada de suavizar
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        } else {
            Image(systemName: slot.isAuto ? "clock.arrow.circlepath" : "square.stack.3d.up.fill")
                .font(.body.weight(.medium))
                .frame(width: 56, height: 42, alignment: .center)
                .foregroundColor(.accentColor)
        }
    }

    @ViewBuilder
    private func slotRow(_ slot: NDSSaveStateSlotInfo) -> some View {
        let locked = isLocked(slot)

        Button {
            if locked {
                pendingSlot = slot.slot
                pendingOffer = ProGateOffer(
                    title: NSLocalizedString("Save Slot is PRO", comment: "Save-slot gate alert title"),
                    message: NSLocalizedString("Slots 2-4 are a PRO feature — slot 1 and auto-save are always free.", comment: "Save-slot gate alert message")
                )
            } else if mode == .save, !slot.isEmpty {
                slotPendingOverwrite = slot
            } else {
                onSelectSlot(slot.slot)
                dismiss()
            }
        } label: {
            HStack(spacing: 14) {
                slotArtwork(slot)

                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.isAuto ? NSLocalizedString("Auto-Save", comment: "") : String(format: NSLocalizedString("Slot %d", comment: ""), slot.slot + 1))
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(slot.isEmpty ? NSLocalizedString("Empty", comment: "") : Self.dateFormatter.string(from: slot.modifiedDate!))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if locked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if mode == .load, slot.isEmpty {
                    // No icon: the row is already disabled and says "Empty".
                    // A padlock here reads as the PRO padlock above it.
                    EmptyView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .disabled(mode == .load && slot.isEmpty)
        .accessibilityElement(children: .combine)
        // Long press to clear a slot. Only where there is something to clear,
        // and only when we know which ROM we belong to.
        .contextMenu {
            if !slot.isEmpty, romBaseName != nil {
                Button(role: .destructive) {
                    slotPendingDeletion = slot
                } label: {
                    Label(NSLocalizedString("Delete Save State", comment: "Context menu action on a save-state slot"),
                          systemImage: "trash")
                }
            }
        }
    }
}
