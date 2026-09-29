//
//  INDSButtonStyleEditorSheet.swift
//  eDuo
//
//  Ported and adapted from iGBA's ButtonStyleEditorSheet.swift. Sheet for
//  editing one button's visual style: label, font, colors
//  (background, text/tint, border — each with its own opacity via
//  `ColorPicker(supportsOpacity: true)`, since `INDSButtonStyle` has no
//  separate opacity field, same as iGBA's `ButtonStyle`), and shape (border
//  width / corner radius).
//
//  Adaptations vs. iGBA:
//   - No "Type" picker and no image import (PhotosUI) flow — eDuo ships no
//     skin artwork, so every button is the vector `.text` look; this sheet
//     only ever writes `.text` styles (see `loadInitial`).
//   - No "Apply to all action buttons" — out of scope for this port; every
//     button is styled independently, same as it's positioned independently.
//
//  Presented as a sheet from `INDSLayoutEditorView` for any selected button
//  except `.dpad` (the D-pad keeps its dedicated vector cross / virtual
//  joystick look and never carries an `INDSButtonStyle`).
//

import SwiftUI
import UIKit

struct INDSButtonStyleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let buttonID: INDSControllerButtonID
    /// Bound style of the currently edited button. `nil` = default vector look.
    @Binding var style: INDSButtonStyle?

    // Working copy so Cancel discards cleanly; committed to `style` on Done.
    @State private var working = INDSButtonStyle()

    // Color pickers work on `Color`; mirrored hex <-> Color via these.
    @State private var textColor: Color = .white
    @State private var backgroundColor = Color(UIColor(white: 0.12, alpha: 0.9))
    @State private var borderColor = Color(UIColor(white: 1.0, alpha: 0.8))

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                labelSection
                fontSection
                colorsSection
                shapeSection
                actionsSection
            }
            .navigationTitle(buttonTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        style = working
                        dismiss()
                    }
                    .font(.body.bold())
                }
            }
            .onAppear(perform: loadInitial)
            .onChange(of: textColor) { _, new in working.textColorHex = INDSButtonStyleColor.encode(UIColor(new)) }
            .onChange(of: backgroundColor) { _, new in working.backgroundColorHex = INDSButtonStyleColor.encode(UIColor(new)) }
            .onChange(of: borderColor) { _, new in working.borderColorHex = INDSButtonStyleColor.encode(UIColor(new)) }
        }
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    // MARK: - Sections

    private var buttonTitle: String {
        String(format: NSLocalizedString("Button Style: %@", comment: "Style sheet title; %@ is the button's label"),
               buttonID.defaultStyleLabel)
    }

    private var previewSection: some View {
        Section {
            HStack {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [Color.gray.opacity(0.25), Color.gray.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom))
                        .frame(height: 140)
                    INDSStyledButtonContent(buttonID: buttonID, style: working, size: CGSize(width: 110, height: 110))
                        .frame(width: 110, height: 110)
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    private var labelSection: some View {
        Section(header: Text("Label")) {
            TextField(buttonID.defaultStyleLabel,
                      text: Binding(get: { working.label ?? "" },
                                    set: { working.label = $0.isEmpty ? nil : $0 }))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.characters)
        }
    }

    private var fontSection: some View {
        Section(header: Text("Font")) {
            Picker("Family",
                   selection: Binding(get: { working.fontName ?? "" },
                                      set: { working.fontName = $0.isEmpty ? nil : $0 })) {
                ForEach(Self.curatedFonts, id: \.fontName) { item in
                    Text(item.displayName).tag(item.fontName)
                }
            }

            VStack(alignment: .leading) {
                Text("Weight")
                Slider(value: $working.fontWeightRaw, in: 0...1)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Size")
                    Spacer()
                    Text(String(format: "%.0f%%", working.fontSizeFraction * 100))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $working.fontSizeFraction, in: 0.2...0.95)
            }
        }
    }

    private var colorsSection: some View {
        Section(header: Text("Colors")) {
            ColorPicker("Text", selection: $textColor, supportsOpacity: true)
            ColorPicker("Background", selection: $backgroundColor, supportsOpacity: true)
            ColorPicker("Border", selection: $borderColor, supportsOpacity: true)
        }
    }

    private var shapeSection: some View {
        Section(header: Text("Shape")) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Border width")
                    Spacer()
                    Text(String(format: "%.1f", working.borderWidth))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $working.borderWidth, in: 0...8)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Corner radius")
                    Spacer()
                    Text(String(format: "%.0f%%", working.cornerRadiusFraction * 200))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $working.cornerRadiusFraction, in: 0...0.5)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button(role: .destructive) {
                style = nil
                dismiss()
            } label: {
                Label("Reset to default", systemImage: "arrow.uturn.backward")
            }
        }
    }

    // MARK: - Logic

    private func loadInitial() {
        working = style ?? .defaultStyle(for: buttonID)
        // This sheet has no image-import flow — any pre-existing `.image`
        // style falls back to a plain text style rather than showing an
        // editor for fields it doesn't have.
        working.kind = .text

        textColor = Color(INDSButtonStyleColor.decode(working.textColorHex) ?? .white)
        backgroundColor = Color(INDSButtonStyleColor.decode(working.backgroundColorHex) ?? UIColor.black.withAlphaComponent(0.6))
        borderColor = Color(INDSButtonStyleColor.decode(working.borderColorHex) ?? UIColor.white.withAlphaComponent(0.8))
    }

    // MARK: - Curated fonts

    /// Fonts that ship with iOS and stay readable at small on-screen-button
    /// sizes. `""` means "system default". Local to this file — no other
    /// screen needs a font picker.
    private static let curatedFonts: [(displayName: String, fontName: String)] = [
        ("System", ""),
        ("Avenir Next", "AvenirNext-Bold"),
        ("Helvetica Neue", "HelveticaNeue-Bold"),
        ("SF Mono", "SFMono-Bold"),
        ("Menlo", "Menlo-Bold"),
        ("Courier New", "CourierNewPS-BoldMT"),
        ("Futura", "Futura-Bold"),
        ("Gill Sans", "GillSans-Bold"),
        ("American Typewriter", "AmericanTypewriter-Bold"),
        ("Marker Felt", "MarkerFelt-Wide"),
        ("Chalkduster", "Chalkduster"),
        ("Optima", "Optima-Bold"),
        ("Georgia", "Georgia-Bold"),
        ("Times New Roman", "TimesNewRomanPS-BoldMT")
    ]
}
