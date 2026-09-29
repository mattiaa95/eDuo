//
//  AppearanceSettingsView.swift
//  eDuo
//
//  Settings → Appearance. Same idea as iGBA's AppearanceSettingsView: a native `ColorPicker` bound to a persisted accent color, applied
//  app-wide via `.tint`, plus the per-orientation background images (iGBA
//  calls them controller skins). iGBA's page also has a GB palette picker —
//  a GBA-only concern with no eDuo equivalent.
//
//  The background images are PRO. iGBA offers "watch an ad instead"; eDuo has
//  no ad SDK at all (docs/LEGAL.md), so the equivalent "try before you buy" is
//  the first-48h honeymoon, which unlocks this like every other gate.
//

import PhotosUI
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var appearance = INDSAppearanceStore.shared
    @ObservedObject private var entitlements = EntitlementManager.shared

    @State private var portraitItem: PhotosPickerItem?
    @State private var landscapeItem: PhotosPickerItem?
    @State private var previews: [INDSBackgroundSkinOrientation: UIImage] = [:]
    @State private var pendingOffer: ProGateOffer?

    private var isEntitled: Bool {
        entitlements.hasPro || INDSHoneymoon.isActive
    }

    var body: some View {
        Form {
            Section {
                ColorPicker("Accent Color", selection: $appearance.accentColor, supportsOpacity: false)
            } header: {
                Text("🎨 Accent Color")
            } footer: {
                Text("Sets the tint used for buttons, links and highlights across eDuo.")
            }

            Section {
                ColorPicker("Game Background", selection: $appearance.gameBackgroundColor, supportsOpacity: false)
            } header: {
                Text("🖼️ Emulation")
            } footer: {
                Text("Fills the space around and between the two screens while playing. Applies the next time you open a game.")
            }

            Section {
                skinRow(.portrait, item: $portraitItem)
                skinRow(.landscape, item: $landscapeItem)
            } header: {
                Text("🏞️ Background Image")
            } footer: {
                Text(isEntitled
                     ? "Pick a photo to sit behind the screens and the controls. Each orientation has its own image, and it changes as soon as you rotate. The background colour above shows through wherever no image is set."
                     : "Set your own photo behind the screens and the controls, with a separate image for portrait and landscape. Included in eDuo PRO.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearance.accentColor)
        .proGateAlert(offer: $pendingOffer)
        .onAppear(perform: loadPreviews)
    }

    // MARK: - Rows

    @ViewBuilder
    private func skinRow(_ orientation: INDSBackgroundSkinOrientation,
                         item: Binding<PhotosPickerItem?>) -> some View {
        HStack {
            if isEntitled {
                PhotosPicker(selection: item, matching: .images, photoLibrary: .shared()) {
                    Label(orientation.displayName, systemImage: "photo")
                }
                .onChange(of: item.wrappedValue) { _, newItem in
                    guard let newItem else { return }
                    Task { await apply(newItem, to: orientation) }
                }
            } else {
                Button {
                    pendingOffer = ProGateOffer(
                        title: NSLocalizedString("Background Images are PRO", comment: "Background skin gate title"),
                        message: NSLocalizedString("Go PRO to use your own photos behind the screens, with a separate background for portrait and landscape.",
                                                   comment: "Background skin gate message")
                    )
                } label: {
                    Label("\(orientation.displayName) 🔒", systemImage: "photo")
                }
            }

            Spacer(minLength: 12)

            // Only while entitled: once the honeymoon ends (or a subscription
            // lapses) the emulator stops applying the image, so still showing
            // a thumbnail would advertise a background that isn't there.
            if isEntitled, let preview = previews[orientation] {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1))

                Button {
                    remove(orientation)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove"))
            }
        }
    }

    // MARK: - Actions

    private func loadPreviews() {
        for orientation in INDSBackgroundSkinOrientation.allCases {
            previews[orientation] = INDSBackgroundSkinStore.thumbnail(for: orientation)
        }
    }

    /// Decode + downsample + write happen off the main thread; a full-size
    /// camera-roll photo is big enough that doing it inline drops frames on
    /// the Settings list.
    private func apply(_ item: PhotosPickerItem, to orientation: INDSBackgroundSkinOrientation) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let stored = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(data: data) else { return nil }
            INDSBackgroundSkinStore.set(image, for: orientation)
            return INDSBackgroundSkinStore.thumbnail(for: orientation)
        }.value
        guard let stored else { return }
        previews[orientation] = stored
        INDSHaptics.light()
    }

    private func remove(_ orientation: INDSBackgroundSkinOrientation) {
        INDSBackgroundSkinStore.set(nil, for: orientation)
        previews[orientation] = nil
        if orientation == .portrait { portraitItem = nil } else { landscapeItem = nil }
        INDSHaptics.light()
    }
}
