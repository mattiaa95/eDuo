//
//  NDSCheatsView.swift
//  eDuo
//
//  New (no iGBA equivalent — GBA cheats are a different, simpler format).
//  Per-game cheat list sheet presented from the pause menu. Unlike the other
//  pause-menu sheets, rows here need real swipe-to-delete, which SwiftUI only
//  honors inside a `List` — so this one uses `List` + `.listRowBackground`
//  to approximate the card look the rest of the module gets from a plain
//  ScrollView of rows, rather than the ScrollView+VStack pattern itself.
//
//  Storage is the on-disk `.mch` file itself (`NDSCheatFileStore`) — no
//  separate database — so this view reads it once in `.onAppear` and
//  rewrites it after every add/edit/delete/toggle, then calls
//  `onCheatsChanged` so the caller pushes the fresh file into the live core
//  (`MelonDSCoreBridge.reloadCheats(fromFile:enabled:)`). Free for everyone
//  — no Pro gate.
//

import SwiftUI

struct NDSCheatsView: View {
    let romBaseName: String
    let onCheatsChanged: () -> Void

    @State private var cheats: [NDSCheat] = []
    @State private var isAddingNew = false
    @State private var editingCheat: NDSCheat?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            HStack {
                Spacer()
                Text(NSLocalizedString("Cheats", comment: ""))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button {
                    INDSHaptics.light()
                    isAddingNew = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .padding(.trailing, 16)
                .accessibilityLabel(NSLocalizedString("Add Cheat", comment: ""))
            }
            .padding(.bottom, 10)

            if cheats.isEmpty {
                emptyState
                Spacer()
            } else {
                cheatList
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            cheats = NDSCheatFileStore.load(forBaseName: romBaseName)
        }
        .sheet(isPresented: $isAddingNew) {
            NDSCheatEditorView(cheat: nil) { newCheat in
                cheats.append(newCheat)
                persist()
            }
        }
        .sheet(item: $editingCheat) { cheat in
            NDSCheatEditorView(cheat: cheat) { updated in
                guard let idx = cheats.firstIndex(where: { $0.id == updated.id }) else { return }
                cheats[idx] = updated
                persist()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text(NSLocalizedString("No Cheats Yet", comment: ""))
                .font(.body.weight(.medium))
            Text(NSLocalizedString("Tap + to add an Action Replay code for this game.", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var cheatList: some View {
        List {
            ForEach(cheats) { cheat in
                cheatRow(cheat)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(cheat)
                        } label: {
                            Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The edit button and the enable toggle are deliberate siblings (not
    /// one nested in the other's label) — a `Toggle` inside a `Button`'s
    /// label is unreliable about which control actually receives the tap.
    @ViewBuilder
    private func cheatRow(_ cheat: NDSCheat) -> some View {
        HStack(spacing: 14) {
            Button {
                INDSHaptics.light()
                editingCheat = cheat
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cheat.name)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(String(format: NSLocalizedString("%d code line(s)", comment: "Cheat code line count"), NDSCheatValidation.codeLines(cheat.code).count))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { cheat.enabled },
                set: { setEnabled($0, for: cheat) }
            ))
            .labelsHidden()
            .accessibilityLabel(cheat.name)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private func setEnabled(_ enabled: Bool, for cheat: NDSCheat) {
        guard let idx = cheats.firstIndex(where: { $0.id == cheat.id }) else { return }
        // A cheat with no valid code lines can never be turned on — mirrors
        // the bridge's own empty-Code guard (see NDSCheatValidation.isValid),
        // checked here too so the UI never shows a toggle "on" for something
        // the engine would refuse to run anyway.
        guard !enabled || NDSCheatValidation.isValid(cheats[idx].code) else { return }
        INDSHaptics.light()
        cheats[idx].enabled = enabled
        persist()
    }

    private func delete(_ cheat: NDSCheat) {
        INDSHaptics.light()
        cheats.removeAll { $0.id == cheat.id }
        persist()
    }

    private func persist() {
        NDSCheatFileStore.save(cheats, forBaseName: romBaseName)
        onCheatsChanged()
    }
}

// MARK: - Add / Edit sheet

private struct NDSCheatEditorView: View {
    /// `nil` when adding a new cheat.
    let cheat: NDSCheat?
    let onSave: (NDSCheat) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var code: String

    init(cheat: NDSCheat?, onSave: @escaping (NDSCheat) -> Void) {
        self.cheat = cheat
        self.onSave = onSave
        _name = State(initialValue: cheat?.name ?? "")
        _code = State(initialValue: cheat?.code ?? "")
    }

    private var isCodeValid: Bool { NDSCheatValidation.isValid(code) }
    private var codeFormat: NDSCheatValidation.CodeFormat? { NDSCheatValidation.format(of: code) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && isCodeValid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("Cheat Name", comment: ""), text: $name)
                } header: {
                    Text(NSLocalizedString("Name", comment: ""))
                }

                Section {
                    TextEditor(text: $code)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                } header: {
                    Text(NSLocalizedString("Code", comment: ""))
                } footer: {
                    // CodeBreaker/CodeFreak lists look exactly like Action
                    // Replay ones and the engine runs them without a word
                    // (doing nothing) — so say what was recognised, and
                    // what will actually be saved.
                    switch codeFormat {
                    case .codeBreaker:
                        Text(NSLocalizedString("CodeBreaker/CodeFreak code detected. It will be saved as the equivalent Action Replay code.", comment: "Cheat editor note"))
                    case .codeBreakerUnsupported:
                        Text(NSLocalizedString("This CodeBreaker/CodeFreak code uses a code type eDuo can't convert to Action Replay.", comment: "Cheat code validation error"))
                            .foregroundColor(.red)
                    case .actionReplay, nil:
                        if !code.isEmpty && !isCodeValid {
                            Text(NSLocalizedString("Each line must be two 8-digit hex values separated by a space, e.g. 94000130 FFFB0000.", comment: "Cheat code validation error"))
                                .foregroundColor(.red)
                        } else {
                            Text(NSLocalizedString("One code line per pair: address then value, e.g. 94000130 FFFB0000.", comment: "Cheat code format hint"))
                        }
                    }
                }
            }
            .navigationTitle(cheat == nil ? NSLocalizedString("New Cheat", comment: "") : NSLocalizedString("Edit Cheat", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Save", comment: "")) { save() }
                        .disabled(!canSave)
                }
            }
        }
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    private func save() {
        // A cheat the user just typed in starts ON. melonDS's Qt frontend
        // defaults a new AR code to off, but there the code list is a desktop
        // window kept open next to the game; here it's a sheet the user opened
        // to make something happen right now, and a new row landing with its
        // toggle off reads as "I added the cheat and nothing happened".
        // Editing an existing one preserves whatever it was; `canSave`
        // already guarantees `code` is valid either way, so this can never
        // persist an enabled-but-invalid cheat.
        // Store the lines the engine will run (canonical Action Replay,
        // translated if the user pasted CodeBreaker) — that is what the
        // .mch holds and what the list shows after a reload anyway.
        var updated = NDSCheat(
            name: name.trimmingCharacters(in: .whitespaces),
            code: NDSCheatValidation.normalizedLines(code).joined(separator: "\n"),
            enabled: cheat?.enabled ?? true
        )
        if let existingID = cheat?.id {
            updated.id = existingID
        }
        onSave(updated)
        dismiss()
    }
}
