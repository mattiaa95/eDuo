import SwiftUI

/// Long-press a 3DS game › "Texture Packs…": the game's one texture folder (packs and dumps
/// both live there) and the "Dump Textures" switch. Same long-press-menu family as "Save Data" (ROMSaveTransferController).
struct ThreeDSTexturePacksView: View {
    let rom: ROMFile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var dumping: Bool

    private let programID: UInt64

    init(rom: ROMFile) {
        self.rom = rom
        let id = ThreeDSSaveTransfer.programID(for: rom) ?? 0
        programID = id
        _dumping = State(initialValue: ThreeDSTexturePacks.isDumping(programID: id))
    }

    private var idText: String { ThreeDSTexturePacks.idString(programID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Game ID")
                        Spacer()
                        Text(idText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let folder = ThreeDSTexturePacks.packFolder(programID: programID) {
                        Button("Open Pack Folder") { open(folder, create: true) }
                    }
                } footer: {
                    Text("Textures live in Files › eDuo › System › load › textures › \(idText). Edit them there and start the game again.")
                }
                Section {
                    Toggle("Dump Textures", isOn: $dumping)
                } footer: {
                    Text("Saves the textures the game draws into that same folder, adding new ones every time you play. Slows the game down, so turn it off when you are done. Nintendo 3DS games only.")
                }
            }
            .navigationTitle("Texture Packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { ThreeDSTexturePacks.migrateLegacyDump(programID: programID) }
            .onChange(of: dumping) { _, on in
                ThreeDSTexturePacks.setDumping(on, programID: programID)
            }
        }
    }

    private func open(_ folder: URL, create: Bool) {
        if let url = ThreeDSTexturePacks.filesURL(for: folder, create: create) { openURL(url) }
    }
}
