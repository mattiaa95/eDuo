import SwiftUI

extension Notification.Name {
    /// Posted when an emulation screen leaves the hierarchy, so the library
    /// re-reads play time, last-played and save-state state it shows per cell.
    static let emulationSessionEnded = Notification.Name("eNDSEmulationSessionEnded")
}

/// The in-game HUD actions, for the system toolbar. Filled in by
/// `NDSRomViewController`, which also says when there is a vertical bar.
final class NDSGameChrome: ObservableObject {
    @Published var usesVerticalBar = false
    @Published var fastForwardSpeed: Double?
    var pause: (() -> Void)?
    var cycleLayout: (() -> Void)?
    var fastForward: (() -> Void)?
}

struct EmulationView: View {
    let rom: ROMFile
    @StateObject private var chrome = NDSGameChrome()
    @State private var sessionTimer: Timer?
    /// Balances `ROMStorageManager.markOpen`/`markClosed` across a double
    /// `onAppear` (see the timer below) so the ROM is never left registered
    /// as open after this screen is gone.
    @State private var isRegisteredOpen = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if rom.isThreeDS {
                ThreeDSGameView(rom: rom, onQuit: { dismiss() })
            } else {
                NDSRomViewWrapper(rom: rom, chrome: chrome, onQuitToLibrary: { dismiss() })
            }
        }
            .ignoresSafeArea()
            // Full-immersion emulation screen, iGBA-style: no system nav bar
            // while playing. "Quit to Library" in the pause menu (or an edge
            // swipe-back) is the way out. The exception is a system with a
            // vertical bar (iPhone Duo): that column is there anyway, so the
            // HUD actions live in it, one item each so the system stacks them.
            .toolbar(chrome.usesVerticalBar ? .visible : .hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if chrome.usesVerticalBar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { chrome.pause?() } label: {
                            Label(NSLocalizedString("Menu", comment: "HUD button caption: opens the pause menu"), systemImage: "pause.fill")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { chrome.cycleLayout?() } label: {
                            Label(NSLocalizedString("Layout", comment: "HUD button caption: cycles the screen layout"), systemImage: "rectangle.split.1x2")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { chrome.fastForward?() } label: {
                            Label(chrome.fastForwardSpeed.map(INDSSpeedPreferences.label)
                                  ?? NSLocalizedString("Speed", comment: "HUD button caption: cycles fast forward speed"),
                                  systemImage: chrome.fastForwardSpeed == nil ? "forward" : "forward.fill")
                        }
                    }
                }
            }
            .onAppear {
                rom.recordingPlayStart()
                if !isRegisteredOpen {
                    ROMStorageManager.markOpen(baseName: rom.baseName)
                    isRegisteredOpen = true
                }
                sessionTimer?.invalidate() // a double onAppear must not double-count
                sessionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                    rom.incrementPlayTime(by: 60)
                }
            }
            .onDisappear {
                sessionTimer?.invalidate()
                sessionTimer = nil
                if isRegisteredOpen {
                    ROMStorageManager.markClosed(baseName: rom.baseName)
                    isRegisteredOpen = false
                }
                NotificationCenter.default.post(name: .emulationSessionEnded, object: nil)
            }
    }
}
