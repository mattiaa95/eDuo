import SwiftUI
import UniformTypeIdentifiers

/// Library-side Export Save / Import Save for DS and 3DS games, driven from
/// the long-press menu. The pause menu of a running 3DS game has its own
/// entry points; both use `ROMSaveTransfer` / `ThreeDSSaveTransfer`.
@MainActor
final class ROMSaveTransferController: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    struct SharedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    struct PendingImport {
        let rom: ROMFile
        let staged: URL
    }

    @Published var isPickingSave = false
    @Published var sharedFile: SharedFile?
    @Published var message: Message?
    @Published var pendingImport: PendingImport?
    private var importTarget: ROMFile?

    /// Same picker types for both handhelds: a `.sav`, a `.zip`, or a folder.
    let importContentTypes: [UTType] = [.zip, .folder, .data]

    func exportSave(of rom: ROMFile) {
        Task {
            do {
                // Zipping runs off the main thread; a DS `.sav` is shared as is.
                let url = try await Task.detached(priority: .userInitiated) { try ROMSaveTransfer.exportFile(for: rom) }.value
                sharedFile = SharedFile(url: url)
            } catch {
                message = Message(title: rom.displayName, text: error.localizedDescription)
            }
        }
    }

    func beginImport(for rom: ROMFile) {
        guard !E3DSIsRunning() else {
            message = Message(title: rom.displayName, text: SaveTransferError.gameRunning.localizedDescription)
            return
        }
        importTarget = rom
        isPickingSave = true
    }

    func handlePicked(_ result: Result<[URL], Error>) {
        guard let rom = importTarget else { return }
        importTarget = nil
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task {
            do {
                // Staging copies while the picker's access lasts; the swap itself
                // waits for the player's confirmation when a save already exists.
                let staged = try await Task.detached(priority: .userInitiated) { try ROMSaveTransfer.stageImport(from: urls, for: rom) }.value
                if ROMSaveTransfer.hasSave(rom) {
                    pendingImport = PendingImport(rom: rom, staged: staged)
                } else {
                    install(staged, for: rom)
                }
            } catch {
                message = Message(title: rom.displayName, text: error.localizedDescription)
            }
        }
    }

    func confirmReplace() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        install(pending.staged, for: pending.rom)
    }

    func cancelReplace() {
        if let pending = pendingImport { try? FileManager.default.removeItem(at: pending.staged) }
        pendingImport = nil
    }

    private func install(_ staged: URL, for rom: ROMFile) {
        do {
            try ROMSaveTransfer.installImport(staged, for: rom)
            message = Message(
                title: rom.displayName,
                text: NSLocalizedString("Save imported. Your previous save was kept as a copy in the Saves folder.", comment: "Save import success alert"))
            NotificationCenter.default.post(name: .emulationSessionEnded, object: nil) // library re-reads save state
        } catch {
            message = Message(title: rom.displayName, text: error.localizedDescription)
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ROMSaveTransferModifier: ViewModifier {
    @ObservedObject var controller: ROMSaveTransferController

    func body(content: Content) -> some View {
        content
            // A second `.fileImporter` on the view that already hosts the ROM
            // picker silently never shows; a separate host view works.
            .background(
                Color.clear.fileImporter(
                    isPresented: $controller.isPickingSave,
                    allowedContentTypes: controller.importContentTypes,
                    allowsMultipleSelection: true
                ) { controller.handlePicked($0) }
            )
            .sheet(item: $controller.sharedFile) { file in
                ActivityShareSheet(url: file.url).ignoresSafeArea()
            }
            .alert("Replace Save?", isPresented: Binding(
                get: { controller.pendingImport != nil },
                set: { if !$0 { controller.cancelReplace() } }
            )) {
                Button("Replace", role: .destructive) { controller.confirmReplace() }
                Button("Cancel", role: .cancel) { controller.cancelReplace() }
            } message: {
                Text("This overwrites the save this game has now. A copy of the current save is kept first.")
            }
            .alert(item: $controller.message) { message in
                Alert(title: Text(verbatim: message.title), message: Text(verbatim: message.text), dismissButton: .cancel(Text("OK")))
            }
    }
}

extension View {
    func romSaveTransfer(_ controller: ROMSaveTransferController) -> some View {
        modifier(ROMSaveTransferModifier(controller: controller))
    }
}
