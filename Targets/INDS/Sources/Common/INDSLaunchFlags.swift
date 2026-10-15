import SwiftUI
import Foundation

/// Process-level launch flags. `screenshotHarness` drives the App Store
/// screenshot UITest runs: it keeps the app in its true "fresh device, no
/// controller" presentation, which the simulator can't reproduce naturally
/// (the host keyboard registers as a connected gamepad and would hide the
/// touch overlay in every capture).
enum INDSLaunchFlags {
    static let screenshotHarness =
        ProcessInfo.processInfo.arguments.contains("-eNDSScreenshotHarness")

    /// `-eNDSOpenMapping`: starts straight on the controller mapping screen,
    /// for simulator captures (no way to tap through Settings headless).
    static let openMapping =
        ProcessInfo.processInfo.arguments.contains("-eNDSOpenMapping")

    /// `-eNDSAutoOpen <text>`: opens the first library game whose name contains
    /// `text` as soon as the library shows. Only for the layout checks
    /// (`scripts/duo_layout_check.sh`), which cannot tap the inner display.
    static let autoOpen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-eNDSAutoOpen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
}

/// Opens the game named by `-eNDSAutoOpen` once the library has it. Inert
/// (no state change, no destination) when the flag is absent.
struct INDSAutoOpenModifier: ViewModifier {
    let roms: [ROMFile]
    @State private var rom: ROMFile?
    @State private var isOpen = false

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isOpen) {
                if let rom { EmulationView(rom: rom) }
            }
            .onAppear(perform: open)
            .onChange(of: roms) { open() }
    }

    private func open() {
        guard let key = INDSLaunchFlags.autoOpen, rom == nil else { return }
        rom = roms.first { $0.filename.localizedCaseInsensitiveContains(key) }
        isOpen = rom != nil
    }
}
