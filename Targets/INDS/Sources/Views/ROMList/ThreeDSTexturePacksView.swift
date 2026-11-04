import SwiftUI

/// Long-press a 3DS game › "Texture Packs…": where packs go, the game's ID and the
/// "Dump Textures" switch. Same long-press-menu family as "Save Data" (ROMSaveTransferController).
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
                    Text("Put a texture pack in Files › eDuo › System › load › textures › \(idText), then start the game again.")
                }
                Section {
                    Toggle("Dump Textures", isOn: $dumping)
                    if ThreeDSTexturePacks.hasDumpedTextures(programID: programID),
                       let folder = ThreeDSTexturePacks.dumpFolder(programID: programID) {
                        Button("Open Dumped Textures") { open(folder, create: false) }
                    }
                } footer: {
                    Text("Saves the textures the game draws as PNG files in Files › eDuo › System › dump › textures › \(idText). Edit them and copy the folder into the load folder. Applies the next time the game starts and slows the game down, so turn it off when you are done. Nintendo 3DS games only.")
                }
            }
            .navigationTitle("Texture Packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: dumping) { _, on in
                ThreeDSTexturePacks.setDumping(on, programID: programID)
            }
        }
    }

    private func open(_ folder: URL, create: Bool) {
        if let url = ThreeDSTexturePacks.filesURL(for: folder, create: create) { openURL(url) }
    }
}
