import SwiftUI

struct BIOSSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var importError: String?
    @State private var installed = Set(BIOSFileKind.allCases.filter { BIOSManager.isInstalled($0) })
    @State private var isImportingFont = false
    @State private var hasSystemFont = FileManager.default.fileExists(atPath: Self.systemFontURL.path)

    /// Where the 3D core looks for a font dumped from the player's own console
    /// (patch 0004 makes it win over the built-in replacement).
    static var systemFontURL: URL {
        URL.documentsDirectory.appendingPathComponent("System/sysdata/shared_font.bin")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("BIOS/firmware files are optional. eDuo can boot and run almost any game using a built-in compatibility BIOS. Importing real dumps from your own console can improve compatibility for a few games. eDuo does not include or download BIOS files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // An encrypted retail dump cannot boot without the ARM7
                    // BIOS: the built-in one has no decryption key.
                    Text("Encrypted game files need bios7.bin to start.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Optional files") {
                    ForEach(BIOSFileKind.allCases) { kind in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.rawValue)
                                    .font(.headline)
                                Text(kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: installed.contains(kind) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(installed.contains(kind) ? .green : .secondary)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("shared_font.bin").font(.headline)
                        Spacer()
                        Image(systemName: hasSystemFont ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(hasSystemFont ? .green : .secondary)
                    }
                    Button {
                        isImportingFont = true
                    } label: {
                        Label("Import System Font", systemImage: "textformat")
                    }
                    .fileImporter(isPresented: $isImportingFont, allowedContentTypes: [.data]) { result in
                        importSystemFont(result)
                    }
                } header: {
                    Text("System font for 3D games")
                } footer: {
                    Text("Fixes garbled text in some Japanese games. Use shared_font.bin dumped from your own console.")
                }

                Section {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import BIOS/Firmware Files", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("Accepted names: bios7.bin, bios9.bin, firmware.bin. Files are validated by expected size and stored locally inside the app container.")
                }
            }
            .navigationTitle("BIOS Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.ndsBIOS],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert("BIOS Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? NSLocalizedString("The selected file could not be imported.", comment: "BIOS import failure alert: fallback when the error carries no message"))
        }
    }

    private func importSystemFont(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A dump is the font with a 0x80-byte header in front: "CFNT"/"CFNU" at 0x80.
        guard let data = try? Data(contentsOf: url), data.count > 0x84, data.count <= 0x332000,
              [Data("CFNT".utf8), Data("CFNU".utf8)].contains(data.subdata(in: 0x80..<0x84)) else {
            importError = NSLocalizedString("That file isn't a system font dump (shared_font.bin).", comment: "System font import error")
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.systemFontURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.systemFontURL, options: .atomic)
            hasSystemFont = true
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var lastError: Error?
            for url in urls {
                do {
                    let kind = try BIOSManager.importFile(from: url)
                    installed.insert(kind)
                } catch {
                    lastError = error
                    debugLog("BIOS import failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importError = lastError?.localizedDescription
            NotificationCenter.default.post(name: .biosFilesChanged, object: nil)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
