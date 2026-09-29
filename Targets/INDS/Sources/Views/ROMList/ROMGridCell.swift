import SwiftUI

/// Grid-mode library card: banner icon art, title, play-time/game-code
/// footer, favorite toggle and a "Resume" badge when a save state exists.
/// Adapted from iGBA's `ROMGridCell` — dark card look, shadow + corner
/// radius — but art is the cartridge's own banner icon (crisper at cell size
/// than a gameplay screenshot) instead of a screenshot, and there's no
/// platform badge since eDuo only ever shows NGame ROMs.
struct ROMGridCell: View {
    let rom: ROMFile
    let onFavoriteToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                ROMIconView(rom: rom, cornerRadius: 0)
                    .padding(20)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(iconBackground)

                HStack {
                    Spacer()
                    favoriteButton
                }
                .padding(6)

                if rom.hasAnySaveState {
                    VStack {
                        Spacer()
                        resumeBadge
                    }
                }
            }
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(rom.displayName)
                    // A text style (12pt at the default size) so this grows
                    // with Dynamic Type instead of sitting at 12pt from XS all
                    // the way to AX5; `.system(size:)` never scales. A fixed
                    // minHeight clipped the second line as soon as the text
                    // grew.
                    .font(.system(.caption, design: .default, weight: .semibold).width(.standard))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 30, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(rom.playTime > 0 ? rom.formattedPlayTime : rom.gameCode)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
    }

    private var iconBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.21, green: 0.21, blue: 0.27), Color(red: 0.10, green: 0.10, blue: 0.13)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var favoriteButton: some View {
        Button(action: onFavoriteToggle) {
            Image(systemName: rom.isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(rom.isFavorite ? .yellow : .white.opacity(0.7))
                .motionBounceSymbolEffect(value: rom.isFavorite)
                .padding(6)
                .background(.black.opacity(0.4), in: Circle())
                // The glyph stays small, but the hit area reaches the 44pt the
                // HIG asks for: this button lives INSIDE the NavigationLink
                // that opens the game, so missing the tap did not mean "the
                // favourite did not toggle", it meant booting the emulator and
                // having to back out of it.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rom.isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    private var resumeBadge: some View {
        HStack {
            HStack(spacing: 3) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text("Resume")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.85), in: Capsule())
            Spacer()
        }
        .padding(6)
    }
}
