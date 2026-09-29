import SwiftUI
import UniformTypeIdentifiers

struct ROMListView: View {
    @EnvironmentObject private var viewModel: ROMListViewModel
    @ObservedObject private var entitlements = EntitlementManager.shared
    @State private var isImportingROM = false
    /// True while a picked batch is being copied/extracted off the main
    /// thread — drives the "Importing…" overlay so a big `.7z` doesn't look
    /// like the picker silently did nothing.
    @State private var importInProgress = false
    @State private var pendingDuplicateURL: URL?
    @State private var romToDelete: ROMFile?
    @State private var romToRename: ROMFile?
    @State private var renameText = ""
    @State private var showingBIOSSetup = false
    @State private var showingSettings = false
    @State private var showingWelcome = false

    /// Filenames (`ROMFile.id`) imported by the most recent successful
    /// import — drives the brief "new" cell highlight below. Cleared a beat
    /// after `importToastMessage` itself fades out.
    @State private var recentlyImportedIDs: Set<String> = []
    /// Subtle "import succeeded" toast (checkmark + text) shown in place of
    /// an alert — see `presentImportSuccess`. The existing "Import Failed"
    /// alert (below) is untouched; this only covers the success path.
    @State private var importToastMessage: String?
    /// Slow ambient pulse behind the empty-state icon.
    @State private var emptyStateGlowPulse = false

    // Note: `.data` instead of our own `.ndsROM` on purpose. If another
    // emulator that also exports `.nds` is installed (or the file comes from a
    // cloud provider that types it as plain `public.data`), the system types
    // the dumped ROM as *that* UTI and the picker greys it out — the file the
    // user came to import is the one file they cannot pick. Extensions are
    // validated in `ROMStorageManager`, which shows a clear "Unsupported file
    // type" alert, so the only thing lost here is the grey-out.
    private let importContentTypes: [UTType] = [.data]

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.filteredROMs.isEmpty {
                    if viewModel.searchQuery.isEmpty {
                        emptyState
                    } else {
                        noSearchResultsState
                    }
                } else {
                    libraryContent
                }
            }
            .navigationTitle("eDuo")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                importSuccessToast
            }
            .overlay {
                if importInProgress {
                    ProgressView("Importing…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .transition(.opacity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingBIOSSetup = true
                    } label: {
                        // BIOS is optional (FreeBIOS) — never an alarming icon.
                        Image(systemName: viewModel.biosInstalled ? "checkmark.shield" : "shield")
                    }
                    .accessibilityLabel("BIOS setup")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.viewMode = viewModel.viewMode.next
                        }
                    } label: {
                        Image(systemName: viewModel.viewMode.next.iconName)
                    }
                    .accessibilityLabel("Switch layout")

                    Button {
                        isImportingROM = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import ROM")
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search Games")
            // No BIOS banner: melonDS boots with FreeBIOS out of the box —
            // real BIOS files are an optional compatibility extra (Settings
            // and the shield toolbar icon cover it). An alarming "required"
            // banner here would contradict the onboarding's "no BIOS needed".
            .safeAreaInset(edge: .bottom) {
                if !viewModel.filteredROMs.isEmpty {
                    sortPicker
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .refreshable {
                viewModel.reload()
            }
        }
        .fileImporter(
            isPresented: $isImportingROM,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleROMImport(result)
        }
        .sheet(isPresented: $showingBIOSSetup, onDismiss: viewModel.reload) {
            BIOSSetupView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showingWelcome, onDismiss: {
        }) {
            WelcomeView {
                isImportingROM = true
            }
        }
        .alert("Already Exists", isPresented: Binding(
            get: { pendingDuplicateURL != nil },
            set: { if !$0 { pendingDuplicateURL = nil } }
        )) {
            Button("Replace") {
                if let pendingDuplicateURL {
                    runImport([pendingDuplicateURL], replaceExisting: true)
                }
                pendingDuplicateURL = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDuplicateURL = nil
            }
        } message: {
            Text("This file already exists in your library. Replace it?")
        }
        .alert("Import Failed", isPresented: Binding(
            get: { viewModel.importErrorMessage != nil },
            set: { if !$0 { viewModel.importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.importErrorMessage = nil }
        } message: {
            // `verbatim:` on purpose: the message is a runtime string that is
            // already localized where it is produced; only the fallback is a
            // literal, so it gets localized here.
            Text(verbatim: viewModel.importErrorMessage
                 ?? NSLocalizedString("The file could not be imported.", comment: "Import failure alert: fallback when the error carries no message"))
        }
        .alert("Rename ROM", isPresented: Binding(
            get: { romToRename != nil },
            set: { if !$0 { romToRename = nil } }
        ), presenting: romToRename) { rom in
            TextField("Name", text: $renameText)
            Button("Rename") {
                viewModel.rename(rom, toBaseName: renameText)
                romToRename = nil
            }
            Button("Cancel", role: .cancel) {
                romToRename = nil
            }
        } message: { rom in
            Text("Renaming \"\(rom.displayName)\" also renames its save file, save states, thumbnail and icon so nothing is lost.")
        }
        .confirmationDialog("Delete ROM?", isPresented: Binding(
            get: { romToDelete != nil },
            set: { if !$0 { romToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete ROM Only", role: .destructive) {
                if let romToDelete {
                    viewModel.delete(romToDelete, alsoDeleteSaveData: false)
                }
                romToDelete = nil
            }
            Button("Delete ROM + Save Data", role: .destructive) {
                if let romToDelete {
                    viewModel.delete(romToDelete, alsoDeleteSaveData: true)
                }
                romToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                romToDelete = nil
            }
        } message: {
            Text("\"ROM Only\" keeps its battery save and save states in case you re-import it later. \"ROM + Save Data\" removes everything for this game.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .romImported)) { notification in
            viewModel.reload()
            // "Open in eDuo" from Files/AirDrop: same toast + highlight as
            // the in-app picker, otherwise the library just silently reloads.
            presentImportSuccess(filenames: notification.userInfo?["filenames"] as? [String] ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .romImportFailed)) { notification in
            viewModel.importErrorMessage = notification.userInfo?["message"] as? String
                ?? NSLocalizedString("The file could not be imported.", comment: "Import failure alert: fallback when the error carries no message")
        }
        .onReceive(NotificationCenter.default.publisher(for: .biosFilesChanged)) { _ in
            viewModel.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .emulationSessionEnded)) { _ in
            // "Continue Playing", play time and the Resume badge all read
            // UserDefaults/disk inside `body`; nothing republishes them on
            // the way back from a game otherwise.
            viewModel.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .romImportNeedsReplaceConfirm)) { note in
            // An externally opened .sav would clobber a live battery save —
            // reuse the picker's "Already Exists" alert instead of overwriting.
            if let url = note.userInfo?["url"] as? URL { pendingDuplicateURL = url }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splashDidComplete)) { _ in
            // First-launch-only gate — mirrors iGBA's own onAppearActions
            // pattern (mark seen up front, then present after a beat).
            guard !INDSWelcomeGate.hasSeenWelcome else {
                return
            }
            INDSWelcomeGate.hasSeenWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Two presentations on one view → SwiftUI drops one silently.
                guard !showingSettings, !showingBIOSSetup else { return }
                showingWelcome = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .welcomeGuideRequested)) { _ in
            // Reopen on demand (Settings > About > "Welcome Guide"): dismiss
            // Settings first so the two full-screen presentations don't race.
            showingSettings = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showingWelcome = true
            }
        }
    }

    // MARK: - Library content

    private let gridColumns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 14)]
    private let classicColumns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)]

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let continueROM = viewModel.continuePlayingROM {
                    continueRow(continueROM)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }

                Group {
                    switch viewModel.viewMode {
                    case .grid:
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(viewModel.filteredROMs) { rom in
                                cell(for: rom) {
                                    ROMGridCell(rom: rom, onFavoriteToggle: { viewModel.toggleFavorite(rom) })
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    case .classic:
                        LazyVGrid(columns: classicColumns, spacing: 12) {
                            ForEach(viewModel.filteredROMs) { rom in
                                cell(for: rom) {
                                    ROMClassicCell(rom: rom, onFavoriteToggle: { viewModel.toggleFavorite(rom) })
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.top, viewModel.continuePlayingROM == nil ? 10 : 0)
            }
            .padding(.bottom, 24)
        }
        // Dark "game shelf" backdrop for the library grid itself (cards pop
        // more on dark regardless of system light/dark mode), independent of
        // the rest of the screen (nav bar, empty state, alerts stay adaptive).
        .background(Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea(edges: .bottom))
    }

    private func continueRow(_ rom: ROMFile) -> some View {
        NavigationLink(destination: EmulationView(rom: rom)) {
            HStack(spacing: 12) {
                ROMIconView(rom: rom, cornerRadius: 10)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue Playing")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(rom.displayName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(Color(red: 0.14, green: 0.14, blue: 0.19), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableScaleStyle())
    }

    @ViewBuilder
    private func cell<Content: View>(for rom: ROMFile, @ViewBuilder content: () -> Content) -> some View {
        let isRecentlyImported = recentlyImportedIDs.contains(rom.id)

        NavigationLink(destination: EmulationView(rom: rom)) {
            content()
                .overlay {
                    if isRecentlyImported {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .shadow(color: Color.accentColor.opacity(0.7), radius: 6)
                            .transition(.opacity)
                    }
                }
                .motionAnimation(INDSMotion.gentle, value: isRecentlyImported)
        }
        .buttonStyle(PressableScaleStyle())
        .contextMenu {
            Button {
                // Pre-fill with the ROM's actual filename (not the fancier
                // banner-derived `displayName`) so confirming without editing
                // is a predictable no-op, matching Files app's own Rename UX.
                renameText = rom.baseName
                romToRename = rom
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            ShareLink(item: rom.fileURL) {
                Label("Share ROM", systemImage: "square.and.arrow.up")
            }
            if let saveURL = rom.saveFileURL, rom.hasSaveFile {
                ShareLink(item: saveURL) {
                    Label("Export Save", systemImage: "square.and.arrow.down")
                }
            }
            Button(role: .destructive) {
                romToDelete = rom
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } preview: {
            ROMDetailView(rom: rom)
        }
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $viewModel.sortOption) {
            ForEach(ROMListViewModel.SortOption.allCases) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            emptyStateIcon

            VStack(spacing: 8) {
                Text("Add your first game")
                    .font(.title2.bold())
                Text("Import legal .nds backups — or .zip/.7z archives containing them — from the Files app to start building your eDuo library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                isImportingROM = true
            } label: {
                Label("Import ROMs", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .pressableScale()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Large DS-flavored glyph with a soft ambient glow that breathes slowly
    /// behind it — static (no pulse) under Reduce Motion, per `INDSMotion`.
    private var emptyStateIcon: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color.accentColor.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 95)
                )
                .frame(width: 190, height: 190)
                .scaleEffect(emptyStateGlowPulse ? 1.08 : 0.92)

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 62))
                .foregroundStyle(
                    LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
        .accessibilityHidden(true)
        .onAppear {
            guard let pulse = INDSMotion.pulse else { return }
            withAnimation(pulse) { emptyStateGlowPulse = true }
        }
    }

    /// Mini empty state for a search with zero matches — distinct from the
    /// "library is genuinely empty" state above, which is never shown while
    /// a search query is active.
    private var noSearchResultsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No games match \u{201C}\(viewModel.searchQuery)\u{201D}")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Try a different title or game code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Subtle "import succeeded" checkmark toast — see `presentImportSuccess`.
    @ViewBuilder
    private var importSuccessToast: some View {
        if let importToastMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(importToastMessage)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }

    private func handleROMImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            runImport(urls, replaceExisting: false)
        case .failure(let error):
            viewModel.importErrorMessage = error.localizedDescription
        }
    }

    /// Copies/extracts `urls` off the main thread (a big `.7z` is LZMA-
    /// decompressed in full and used to freeze the UI for seconds), then hops
    /// back to update the library and show the toast / duplicate / error UI.
    /// Same semantics as before: soft failures merge into one alert, a
    /// duplicate `.nds`/`.sav` asks "Replace?" (last one wins if several).
    private func runImport(_ urls: [URL], replaceExisting: Bool) {
        withMotion(INDSMotion.gentle) { importInProgress = true }
        Task.detached(priority: .userInitiated) {
            var importedFilenames: [String] = []
            var messages: [String] = []
            var duplicate: URL?
            for url in urls {
                do {
                    let outcome = try ROMStorageManager.importAny(from: url, replaceExisting: replaceExisting)
                    importedFilenames += outcome.importedROMURLs.map { $0.lastPathComponent }
                    messages += outcome.failureMessages
                } catch ROMStorageError.duplicateFile {
                    duplicate = url
                } catch {
                    messages.append(error.localizedDescription)
                    debugLog("ROM import failed: \(error.localizedDescription)")
                }
            }
            let filenames = importedFilenames, failures = messages, dup = duplicate
            await MainActor.run {
                withMotion(INDSMotion.gentle) { importInProgress = false }
                viewModel.reload()
                if !failures.isEmpty {
                    viewModel.importErrorMessage = failures.joined(separator: "\n")
                }
                if let dup { pendingDuplicateURL = dup }
                presentImportSuccess(filenames: filenames)
            }
        }
    }

    /// Success feedback for a completed import — a brief checkmark toast
    /// (never an alert, that's reserved for the failure path above) plus a
    /// short-lived accent-colored highlight on the newly-added cell(s) if
    /// they're visible in the current sort/filter. Called with whatever
    /// `ROMFile.filename`s actually got imported — a no-op if that's empty
    /// (e.g. every URL in the batch was a duplicate or failed).
    private func presentImportSuccess(filenames: [String]) {
        guard !filenames.isEmpty else { return }

        recentlyImportedIDs = Set(filenames)
        let message: String
        if filenames.count == 1, let rom = viewModel.romFiles.first(where: { $0.filename == filenames[0] }) {
            message = String(format: NSLocalizedString("Added %@", comment: "Import toast, one game: the game's name"),
                             rom.displayName)
        } else {
            message = String(format: NSLocalizedString("Added %d games", comment: "Import toast, several games at once"),
                             filenames.count)
        }
        withMotion(INDSMotion.gentle) {
            importToastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withMotion(INDSMotion.gentle) { importToastMessage = nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withMotion(INDSMotion.gentle) { recentlyImportedIDs.removeAll() }
        }
    }
}

