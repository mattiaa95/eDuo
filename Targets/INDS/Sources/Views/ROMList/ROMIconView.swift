import SwiftUI

/// Shared banner-icon art for the grid cell, classic cell and the
/// context-menu detail preview: the ROM's real 32x32 cartridge icon scaled up
/// with no interpolation (crisp pixel art) once loaded, otherwise a colored
/// initials placeholder in the same footprint. Loads off the main thread and
/// hits `ROMIconStore`'s cache, mirroring iGBA's `ROMGridCell` screenshot
/// loading pattern.
struct ROMIconView: View {
    let rom: ROMFile
    var cornerRadius: CGFloat = 10

    @State private var icon: UIImage?
    /// `loadKey` (`ROMFile.contentKey` + cover stamp) the current `icon` was decoded for. The cell's
    /// identity is the filename, which a "Replace" import keeps, so without
    /// this the old art would survive the new file.
    @State private var loadedKey: String?

    var body: some View {
        ZStack {
            if let icon, rom.hasCustomCover {
                // The user's own picture, any aspect ratio: centered crop that
                // fills the frame, never stretched.
                Color.clear.overlay {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .transition(.opacity)
            } else if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                ROMInitialsPlaceholder(rom: rom)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear(perform: loadIconIfNeeded)
        .onChange(of: loadKey) { loadIconIfNeeded() }
    }

    private var loadKey: String { rom.contentKey + "|" + rom.coverStamp }

    private func loadIconIfNeeded() {
        let key = loadKey
        guard loadedKey != key else { return }
        loadedKey = key
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ROMIconStore.icon(for: rom)
            DispatchQueue.main.async {
                // Crossfade the placeholder out as the real banner art comes
                // in instead of popping — cache hits (the common case, after
                // the first load) resolve almost instantly so this rarely
                // even gets to play, but it's not free on a fresh library.
                withMotion(INDSMotion.fade) {
                    self.icon = loaded
                }
            }
        }
    }
}

/// Fallback shown for ROMs with no parseable banner (some homebrew/hacks):
/// a deterministic-per-game gradient card with the game's initials, in the
/// spirit of iGBA's gradient placeholder cards.
struct ROMInitialsPlaceholder: View {
    let rom: ROMFile

    private var initials: String {
        let words = rom.displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        if let first = words.first {
            return first.prefix(2).uppercased()
        }
        return "DS"
    }

    private var tint: Color {
        var hasher = Hasher()
        hasher.combine(rom.gameCode.isEmpty ? rom.filename : rom.gameCode)
        let bucket = UInt(bitPattern: hasher.finalize()) % 360
        return Color(hue: Double(bucket) / 360.0, saturation: 0.45, brightness: 0.55)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
                .minimumScaleFactor(0.5)
                .padding(6)
        }
    }
}
