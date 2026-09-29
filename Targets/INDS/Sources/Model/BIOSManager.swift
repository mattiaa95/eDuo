import Foundation

enum BIOSFileKind: String, CaseIterable, Identifiable {
    case bios7 = "bios7.bin"
    case bios9 = "bios9.bin"
    case firmware = "firmware.bin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bios7: return NSLocalizedString("ARM7 BIOS", comment: "BIOS file kind")
        case .bios9: return NSLocalizedString("ARM9 BIOS", comment: "BIOS file kind")
        case .firmware: return NSLocalizedString("Firmware", comment: "BIOS file kind")
        }
    }

    var acceptedSizes: Set<Int64> {
        switch self {
        case .bios7: return [16 * 1024]
        case .bios9: return [4 * 1024]
        case .firmware: return [256 * 1024, 512 * 1024]
        }
    }
}

enum BIOSImportError: LocalizedError {
    case unknownFile(String)
    case invalidSize(expected: String, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .unknownFile(let name):
            return String(
                format: NSLocalizedString(
                    "Unknown BIOS/firmware file \"%1$@\". Expected bios7.bin, bios9.bin, or firmware.bin.",
                    comment: "Import Failed alert: the user imported a BIOS/firmware file whose name isn't one of the three expected ones. %1$@ is the filename."
                ),
                name
            )
        case .invalidSize(let expected, let actual):
            return String(
                format: NSLocalizedString(
                    "The file size is %1$@; expected %2$@.",
                    comment: "Import Failed alert: the user imported a BIOS/firmware file of the wrong size. %1$@ is the actual size, %2$@ the expected size."
                ),
                ByteCountFormatter.string(fromByteCount: actual, countStyle: .file),
                expected
            )
        }
    }
}

enum BIOSManager {
    static func url(for kind: BIOSFileKind) throws -> URL {
        try ROMStorageManager.biosDirectoryURL().appendingPathComponent(kind.rawValue)
    }

    static func isInstalled(_ kind: BIOSFileKind) -> Bool {
        guard let url = try? url(for: kind) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Informational only: eDuo boots ROMs fine without any of these files
    /// (melonDS falls back to its built-in FreeBIOS + generated firmware).
    /// Installing real dumps only improves compatibility for a few games.
    static var biosInstalled: Bool {
        BIOSFileKind.allCases.allSatisfy(isInstalled)
    }

    @discardableResult
    static func importFile(from sourceURL: URL) throws -> BIOSFileKind {
        guard let kind = BIOSFileKind(rawValue: sourceURL.lastPathComponent.lowercased()) else {
            throw BIOSImportError.unknownFile(sourceURL.lastPathComponent)
        }

        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        guard kind.acceptedSizes.contains(size) else {
            let expected = kind.acceptedSizes
                .sorted()
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                .joined(separator: " or ")
            throw BIOSImportError.invalidSize(expected: expected, actual: size)
        }

        try ROMStorageManager.copyItem(from: sourceURL, to: try url(for: kind), replaceExisting: true)
        return kind
    }
}
