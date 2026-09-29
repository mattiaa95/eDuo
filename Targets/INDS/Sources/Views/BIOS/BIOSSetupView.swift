import SwiftUI

struct BIOSSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var importError: String?
    @State private var installed = Set(BIOSFileKind.allCases.filter { BIOSManager.isInstalled($0) })

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("BIOS/firmware files are optional. eDuo can boot and run almost any game using a built-in compatibility BIOS. Importing real dumps from your own console can improve compatibility for a few games. eDuo does not include or download BIOS files.")
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
