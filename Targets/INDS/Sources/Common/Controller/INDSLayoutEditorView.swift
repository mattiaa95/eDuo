//
//  INDSLayoutEditorView.swift
//  eDuo
//
//  Ported and adapted from iGBA's ControllerLayoutEditorView.swift. Full-screen canvas for repositioning, resizing, hiding, and
//  restyling on-screen controller buttons, per orientation.
//
//  Adaptations vs. iGBA:
//   - Pushed via a plain `NavigationLink` inside Settings' existing
//     `NavigationStack` (see `ControlsSettingsView`) instead of a separate
//     `UIHostingController` presented `.fullScreen` — eDuo's Settings hub is
//     SwiftUI-native end to end, so there is no legacy UIKit host to bridge
//     from. `Save` writes straight to `INDSControllerLayoutManager`; `Cancel`
//     (or swiping back) just discards the local working copy.
//   - The editable canvas is the FULL view, not a "game placeholder on top /
//     controls strip below" split: eDuo's on-screen controller is a
//     full-bleed overlay across both DS screens (it lets touches that miss a
//     button fall through to the real touch screen underneath — see
//     `NDSControllerView`), so every button's normalizedX/Y is a fraction of
//     the whole bounds, not just a bottom strip. The DS screens are painted
//     as a translucent reference silhouette (via `DSScreenGeometry` +
//     the user's current `DSScreenLayoutPreferences` for the orientation
//     being edited) purely so the user can see what the buttons sit on top
//     of — not editable here.
//   - No preset picker/"Load Preset" menu — eDuo ships no built-in preset
//     library (unlike iGBA's Default/Compact/Wide), only per-user layouts.
//   - Haptics (`INDSHaptics`) on select/drop, which iGBA's editor didn't have.
//

import SwiftUI
import UIKit

struct INDSLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var layout = INDSControllerLayoutManager.shared.activeLayout
    @State private var initialLayout = INDSControllerLayoutManager.shared.activeLayout
    @State private var referenceSizes = INDSControllerLayout.referenceContainerSizes()
    @State private var isPortrait = true
    @State private var selectedButton: INDSControllerButtonID?
    @State private var showResetAlert = false
    @State private var showStyleSheet = false
    /// Set by "Reset to Defaults" so `save()` can tell a reset apart from a
    /// hand-made layout that merely looks like one.
    @State private var didReset = false

    private var currentLayout: Binding<INDSControllerLayout> {
        isPortrait ? $layout.portrait : $layout.landscape
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let size = isPortrait ? referenceSizes.portrait : referenceSizes.landscape
                let scale = min(geo.size.width / size.width, geo.size.height / size.height)
                ZStack {
                    screenSilhouette(in: size)
                    gridGuides(in: size)

                    ForEach(currentLayout.wrappedValue.buttons.indices, id: \.self) { index in
                        let entry = currentLayout.wrappedValue.buttons[index]
                        if entry.isVisible {
                            buttonView(for: entry, index: index, in: size)
                        }
                    }
                }
                // Scale the whole preview: normalized positions and button
                // sizes must share one canvas, including inside an iPad sheet.
                .frame(width: size.width, height: size.height)
                .coordinateSpace(name: "indsLayoutEditorCanvas")
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
            }

            VStack {
                Spacer()
                if let selected = selectedButton {
                    selectedButtonControls(for: selected)
                }
            }
        }
        .navigationTitle("Customize Layout")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .principal) {
                Picker("", selection: $isPortrait) {
                    Text("Portrait").tag(true)
                    Text("Landscape").tag(false)
                }
                .pickerStyle(.segmented)
                // Sized to its labels: "Горизонтальная" needs more than a
                // 100pt segment and UISegmentedControl truncates, never wraps.
                .fixedSize()
                .accessibilityLabel("Orientation")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Buttons") {
                        ForEach(currentLayout.wrappedValue.buttons.indices, id: \.self) { idx in
                            let entry = currentLayout.wrappedValue.buttons[idx]
                            Button {
                                toggleVisibility(of: entry.id)
                            } label: {
                                Label(entry.id.defaultStyleLabel,
                                      systemImage: entry.isVisible ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    Button("Reset to Defaults", role: .destructive) { showResetAlert = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .font(.body.bold())
            }
        }
        .alert("Reset Layout?", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                layout = .defaultLayout(portraitContainer: referenceSizes.portrait,
                                        landscapeContainer: referenceSizes.landscape)
                didReset = true
                selectedButton = nil
                INDSHaptics.medium()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets all button positions, sizes, and styles to their defaults.")
        }
        .sheet(isPresented: $showStyleSheet) {
            if let id = selectedButton,
               let idx = currentLayout.wrappedValue.buttons.firstIndex(where: { $0.id == id }) {
                INDSButtonStyleEditorSheet(
                    buttonID: id,
                    style: Binding(
                        get: { currentLayout.wrappedValue.buttons[idx].style },
                        set: { currentLayout.wrappedValue.buttons[idx].style = $0 }
                    )
                )
            }
        }
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    // MARK: - Save

    /// Writes the working copy to `INDSControllerLayoutManager`, which
    /// persists it to disk and posts `layoutDidChangeNotification` on the
    /// main queue — `NDSControllerView` already observes that and rebuilds,
    /// so any game screen the user returns to reflects the new layout
    /// without further wiring here.
    private func save() {
        // Opening and saving an untouched preview must preserve Automatic.
        if layout != initialLayout {
            let defaults = INDSCustomControllerLayout.defaultLayout(portraitContainer: referenceSizes.portrait,
                                                                    landscapeContainer: referenceSizes.landscape)
            if didReset && layout == defaults {
                // A reset left untouched means "back to Automatic": drop the
                // saved file rather than freezing today's defaults into one,
                // which every other container (an unfolded phone, an iPad
                // window) would then be stuck with.
                INDSControllerLayoutManager.shared.resetToDefault()
            } else {
                INDSControllerLayoutManager.shared.activeLayout = layout
            }
        }
        INDSHaptics.medium()
        dismiss()
    }

    // MARK: - Visibility

    private func toggleVisibility(of id: INDSControllerButtonID) {
        currentLayout.wrappedValue.updateEntry(for: id) { $0.isVisible.toggle() }
        if currentLayout.wrappedValue.entry(for: id)?.isVisible == true {
            selectedButton = id
        } else if selectedButton == id {
            selectedButton = nil
        }
        INDSHaptics.light()
    }

    // MARK: - DS Screen Silhouette (reference only, not editable)

    private func screenSilhouette(in size: CGSize) -> some View {
        let orientationClass: DSScreenOrientationClass = isPortrait ? .portrait : .landscape
        let mode = DSScreenLayoutPreferences.mode(for: orientationClass)
        let swap = DSScreenLayoutPreferences.swapEnabled
        // Mirror the live view: portrait screens stop above the reserved
        // control band, so the silhouette shows the room the buttons actually
        // have rather than pretending they overlap the touch screen.
        let band = isPortrait
            ? INDSControlBand.height(for: INDSControlBand.effectiveIdiom(for: size))
            : 0
        let canvas = CGRect(x: 0, y: 0, width: size.width, height: max(1, size.height - band))
        let frames = DSScreenGeometry.frames(mode: mode, swap: swap, in: canvas)

        return ZStack {
            if let top = frames.top {
                screenRect(top, label: NSLocalizedString("TOP", comment: "Layout editor: label on the top screen silhouette"))
            }
            if let bottom = frames.bottom {
                screenRect(bottom, label: NSLocalizedString("TOUCH", comment: "Layout editor: label on the touch screen silhouette"))
            }
        }
    }

    private func screenRect(_ rect: CGRect, label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.green.opacity(0.5), lineWidth: 1.5)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.green.opacity(0.6))
                .tracking(2)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Grid Guides

    private func gridGuides(in size: CGSize) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            }
            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)

            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)

            ForEach([1, 2], id: \.self) { i in
                let x = size.width * CGFloat(i) / 3
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Button View

    private func buttonView(for entry: INDSButtonLayoutEntry, index: Int, in size: CGSize) -> some View {
        let frame = entry.clampedFrame(in: size)
        let isSelected = selectedButton == entry.id
        let isJoystick = entry.id == .dpad && currentLayout.wrappedValue.directionalInputType == .joystick

        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.12))
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.4), lineWidth: isSelected ? 2 : 1)

            if entry.id == .dpad {
                if isJoystick {
                    INDSJoystickShapePreview().padding(4)
                } else {
                    INDSDPadShapePreview().padding(6)
                }
            } else {
                INDSStyledButtonContent(buttonID: entry.id, style: entry.style,
                                        size: CGSize(width: max(0, frame.width - 6), height: max(0, frame.height - 6)))
                    .padding(3)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .position(x: frame.midX, y: frame.midY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.id.accessibilityName)
        .accessibilityIdentifier("layout-editor-\(entry.id.rawValue)")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            selectedButton = entry.id
            INDSHaptics.light()
        }
        .gesture(
            DragGesture(coordinateSpace: .named("indsLayoutEditorCanvas"))
                .onChanged { value in
                    if selectedButton != entry.id {
                        selectedButton = entry.id
                        INDSHaptics.light()
                    }
                    let newX = max(0.0, min(1.0, value.location.x / size.width))
                    let newY = max(0.0, min(1.0, value.location.y / size.height))
                    currentLayout.wrappedValue.buttons[index].normalizedX = newX
                    currentLayout.wrappedValue.buttons[index].normalizedY = newY
                }
                .onEnded { _ in INDSHaptics.light() }
        )
    }

    // MARK: - Selected Button Controls

    private func selectedButtonControls(for buttonID: INDSControllerButtonID) -> some View {
        VStack(spacing: 8) {
            Divider().background(Color.gray)

            HStack(spacing: 16) {
                Text(buttonID.rawValue.uppercased())
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                HStack {
                    Image(systemName: "minus.magnifyingglass").foregroundColor(.gray)
                    Slider(value: Binding(
                        get: { currentLayout.wrappedValue.entry(for: buttonID)?.scale ?? 1.0 },
                        set: { newValue in
                            currentLayout.wrappedValue.updateEntry(for: buttonID) {
                                $0.scale = max(0.5, min(2.0, newValue))
                            }
                        }
                    ), in: 0.5...2.0, step: 0.1)
                        .frame(width: 120)
                    Image(systemName: "plus.magnifyingglass").foregroundColor(.gray)
                }

                Button {
                    toggleVisibility(of: buttonID)
                } label: {
                    Image(systemName: "eye.slash").foregroundColor(.red)
                }
                .accessibilityLabel(Text("Hide button"))

                if buttonID == .dpad {
                    Button {
                        let current = currentLayout.wrappedValue.directionalInputType
                        currentLayout.wrappedValue.directionalInputType = current == .dpad ? .joystick : .dpad
                        INDSHaptics.light()
                    } label: {
                        Image(systemName: currentLayout.wrappedValue.directionalInputType == .dpad
                              ? "gamecontroller" : "circle.circle")
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityLabel(Text("Toggle D-Pad / Joystick"))
                } else if !buttonID.isHUDChrome {
                    // Menu/Layout are drawn by the HUD as blurred pills, which
                    // ignore the per-button style — offering the editor here
                    // would be a control that silently does nothing.
                    Button {
                        showStyleSheet = true
                    } label: {
                        Image(systemName: "paintbrush").foregroundColor(.accentColor)
                    }
                    .accessibilityLabel(Text("Edit button style"))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color.black.opacity(0.9))
    }
}

// MARK: - Styled Button Content (SwiftUI render, mirrors INDSStyledButtonView)

/// Renders the visual content of a single button (no positioning) from an
/// `INDSButtonStyle` — a SwiftUI counterpart to `INDSStyledButtonView`
/// (UIKit, used by the live overlay) so the editor canvas and the style
/// sheet's preview never drift from what the player actually sees in-game.
struct INDSStyledButtonContent: View {
    let buttonID: INDSControllerButtonID
    let style: INDSButtonStyle?
    let size: CGSize
    var opacity: Double = 1.0

    var body: some View {
        let resolved = style ?? .defaultStyle(for: buttonID)
        Group {
            switch resolved.kind {
            case .image:
                if let image = resolved.customImage() {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(opacity)
                } else {
                    textContent(resolved)
                }
            case .text:
                textContent(resolved)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func textContent(_ style: INDSButtonStyle) -> some View {
        let radius = style.cornerRadius(for: size)
        let label = (style.label?.isEmpty == false) ? style.label! : buttonID.defaultStyleLabel
        let pointSize = max(8, min(size.width, size.height) * CGFloat(style.fontSizeFraction))
        let font: Font = {
            if let name = style.fontName, !name.isEmpty {
                return Font.custom(name, size: pointSize).weight(style.fontWeight.swiftUIWeight)
            }
            return Font.system(size: pointSize, weight: style.fontWeight.swiftUIWeight)
        }()

        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(style.backgroundColor()))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color(style.borderColor()), lineWidth: CGFloat(style.borderWidth))
            Text(label)
                .font(font)
                .foregroundColor(Color(style.textColor()))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
        }
        .opacity(opacity)
    }
}

private extension UIFont.Weight {
    /// `UIFont.Weight` → `Font.Weight`. Local to this file (not added to
    /// `INDSButtonStyle` itself) since only the SwiftUI editor/preview code
    /// needs it — the UIKit runtime renderer uses `UIFont.Weight` directly.
    var swiftUIWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

// MARK: - D-Pad / Joystick Previews (wrap the real runtime views)

/// Wraps the runtime `INDSDPadShapeView` so the editor canvas renders a
/// pixel-identical cross instead of a hand-drawn stand-in. Purely decorative
/// here — `isUserInteractionEnabled = false` so SwiftUI's drag/tap gestures
/// on the enclosing button view keep receiving touches.
private struct INDSDPadShapePreview: UIViewRepresentable {
    func makeUIView(context: Context) -> INDSDPadShapeView {
        let view = INDSDPadShapeView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: INDSDPadShapeView, context: Context) {}
}

/// Wraps the runtime `INDSVirtualJoystickView` (idle look only — touch
/// tracking is disabled) so the joystick preview matches gameplay exactly.
private struct INDSJoystickShapePreview: UIViewRepresentable {
    func makeUIView(context: Context) -> INDSVirtualJoystickView {
        let view = INDSVirtualJoystickView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.baseAlpha = 0.5
        return view
    }
    func updateUIView(_ uiView: INDSVirtualJoystickView, context: Context) {}
}
