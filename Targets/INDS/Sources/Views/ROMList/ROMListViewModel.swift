import Foundation
import SwiftUI

@MainActor
final class ROMListViewModel: ObservableObject {
    enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case dateAdded = "Added"
        case lastPlayed = "Played"
        case size = "Size"
        case system = "System"
        case custom = "Custom"

        var id: String { rawValue }

        /// Localized label for the sort control. Separate from `rawValue`,
        /// which is the persistence key and must stay English.
        var displayName: LocalizedStringKey {
            switch self {
            case .name: return "Name"
            case .dateAdded: return "Added"
            case .lastPlayed: return "Played"
            case .size: return "Size"
            case .system: return "System"
            case .custom: return "Custom"
            }
        }
    }

    /// Library layout. Only grid/classic per spec — no separate "list" mode.
    enum ViewMode: String {
        case grid
        case classic

        var next: ViewMode { self == .grid ? .classic : .grid }
        var iconName: String { self == .grid ? "square.grid.2x2" : "rectangle.grid.1x2" }
    }

    @Published private(set) var romFiles: [ROMFile] = []
    @Published private(set) var filteredROMs: [ROMFile] = []
    @Published var searchQuery = "" {
        didSet { applyFiltersAndSort() }
    }
    /// Remembered between launches (rawValue is the key, so it stays English).
    @Published var sortOption = SortOption(rawValue: UserDefaults.standard.string(forKey: "eduo.romList.sort") ?? "") ?? .name {
        didSet {
            UserDefaults.standard.set(sortOption.rawValue, forKey: "eduo.romList.sort")
            applyFiltersAndSort()
        }
    }
    @Published var importErrorMessage: String?
    @Published var biosInstalled = BIOSManager.biosInstalled

    // Persisted like iGBA's own `romViewMode` — a computed wrapper around
    // `@AppStorage` so toggling it still publishes through `objectWillChange`.
    @AppStorage("romViewMode") private var viewModeRaw: String = ViewMode.grid.rawValue
    var viewMode: ViewMode {
        get { ViewMode(rawValue: viewModeRaw) ?? .grid }
        set {
            objectWillChange.send()
            viewModeRaw = newValue.rawValue
        }
    }

    /// Most recently played ROM, if any — powers the "Continue" row above the
    /// grid/classic content.
    var continuePlayingROM: ROMFile? {
        romFiles
            .filter { $0.lastPlayedDate != nil }
            .max { ($0.lastPlayedDate ?? .distantPast) < ($1.lastPlayedDate ?? .distantPast) }
    }

    init() {
        reload()
    }

    func reload() {
        do {
            romFiles = try ROMStorageManager.listROMs()
            biosInstalled = BIOSManager.biosInstalled
            applyFiltersAndSort()
        } catch {
            debugLog("Failed to load ROM library: \(error.localizedDescription)")
            importErrorMessage = error.localizedDescription
        }
    }

    /// Imports every URL (any mix of `.nds`/`.zip`/`.7z`/`.sav`), reloading
    /// once at the end. Per-URL hard failures (thrown errors) and per-entry
    /// soft failures inside an archive (e.g. one duplicate among five ROMs)
    /// are both merged into `importErrorMessage` rather than aborting the batch.
    @discardableResult
    func importFiles(from urls: [URL], replaceExisting: Bool = false) -> ROMImportResult {
        var aggregate = ROMImportResult()
        var messages: [String] = []

        for url in urls {
            do {
                let result = try ROMStorageManager.importAny(from: url, replaceExisting: replaceExisting)
                aggregate.importedROMURLs += result.importedROMURLs
                aggregate.importedSaveURLs += result.importedSaveURLs
                aggregate.failureMessages += result.failureMessages
                messages += result.failureMessages
            } catch {
                messages.append(error.localizedDescription)
                debugLog("Import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        reload()
        importErrorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
        return aggregate
    }

    func toggleFavorite(_ rom: ROMFile) {
        UserDefaults.standard.set(!rom.isFavorite, forKey: "\(rom.filename)_isFavorite")
        INDSHaptics.light()
        // Deliberately NOT reload(): `isFavorite` reads straight from
        // UserDefaults, so the in-memory ROMFiles are already current. A full
        // reload would re-open and re-parse every ROM's header and banner from
        // disk, on the main actor — two file reads per game before the star
        // even flips. Re-sorting is all this needs.
        applyFiltersAndSort()
    }

    /// Filenames in the order the user dragged them into (Custom sort).
    private static let customOrderKey = "eduo.romList.customOrder"
    private var customOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.customOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.customOrderKey) }
    }

    /// Drag-to-reorder only makes sense on the full, unfiltered list.
    var canReorder: Bool {
        sortOption == .custom && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Live reorder while a game is dragged over another one.
    func moveROM(_ rom: ROMFile, to target: ROMFile) {
        guard canReorder,
              let from = filteredROMs.firstIndex(where: { $0.id == rom.id }),
              let to = filteredROMs.firstIndex(where: { $0.id == target.id }), from != to else { return }
        filteredROMs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        customOrder = filteredROMs.map(\.filename)
    }

    func rename(_ rom: ROMFile, toBaseName newBaseName: String) {
        do {
            try ROMStorageManager.renameROM(rom, toBaseName: newBaseName)
            // Keep the renamed game where the user put it.
            let ext = (rom.filename as NSString).pathExtension
            let newName = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
            customOrder = customOrder.map { $0 == rom.filename ? newName : $0 }
            reload()
        } catch {
            debugLog("Failed to rename ROM \(rom.filename): \(error.localizedDescription)")
            importErrorMessage = error.localizedDescription
        }
    }

    func delete(_ rom: ROMFile, alsoDeleteSaveData: Bool) {
        do {
            try ROMStorageManager.deleteROM(rom, alsoDeleteSaveData: alsoDeleteSaveData)
            reload()
        } catch {
            debugLog("Failed to delete ROM \(rom.filename): \(error.localizedDescription)")
            importErrorMessage = error.localizedDescription
        }
    }

    /// Case, accent and width folded (`pokemon` finds "Pokémon", half-width
    /// kana finds a full-width title) so the search matches how people type,
    /// not how the banner was encoded. NFKC first: `.widthInsensitive` maps
    /// half-width kana but leaves the half-width (semi-)voiced marks alone,
    /// so "ﾎﾟ" would never equal "ポ" without it.
    private static func searchFold(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
    }

    private func applyFiltersAndSort() {
        let query = Self.searchFold(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        filteredROMs = romFiles.filter { rom in
            query.isEmpty
                || Self.searchFold(rom.filename).contains(query)
                || Self.searchFold(rom.displayName).contains(query)
                // The "----" placeholder would make every ROM without a game
                // code match a "-" query.
                || (rom.gameCode != ROMFile.unknownGameCode && Self.searchFold(rom.gameCode).contains(query))
        }

        switch sortOption {
        case .name:
            filteredROMs.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .dateAdded:
            filteredROMs.sort { $0.creationDate > $1.creationDate }
        case .lastPlayed:
            filteredROMs.sort { lhs, rhs in
                switch (lhs.lastPlayedDate, rhs.lastPlayedDate) {
                case let (l?, r?): return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            }
        case .size:
            filteredROMs.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .system:
            // DS games first, then 3DS, each by name.
            filteredROMs.sort { lhs, rhs in
                lhs.isThreeDS != rhs.isThreeDS ? !lhs.isThreeDS
                    : lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        case .custom:
            // The user's order; games never placed (new imports) go last, newest first.
            let rank = Dictionary(customOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            filteredROMs.sort { lhs, rhs in
                switch (rank[lhs.filename], rank[rhs.filename]) {
                case let (l?, r?): return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.creationDate > rhs.creationDate
                }
            }
            return  // the user's arrangement wins over the favourites-first rule
        }

        // Favourites float to the top of whichever sort is active. Until now
        // the star was stored and drawn but changed nothing — you could mark a
        // game and it stayed exactly where it was, which makes the feature look
        // broken rather than absent. A stable partition keeps the chosen sort
        // intact inside each group.
        let favourites = filteredROMs.filter(\.isFavorite)
        if !favourites.isEmpty {
            filteredROMs = favourites + filteredROMs.filter { !$0.isFavorite }
        }
    }
}
