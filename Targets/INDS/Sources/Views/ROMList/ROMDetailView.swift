import SwiftUI

/// Long-press context-menu preview card — shown above the Rename/Share/
/// Export Save/Delete menu, matching iGBA's `ROMDetailView` role and size
/// (`.frame(width: 320)`) exactly. Tapping the card commits the row's
/// default action (Play), same as iGBA's; the "Play" affordance at the
/// bottom is a visual CTA rather than a separately-wired button.
///
/// Hero art is the last-played gameplay thumbnail when one exists (large,
/// per spec); the grid/classic cells show the sharper banner icon instead —
/// this view shows *both*: the thumbnail as a backdrop, and the banner icon
/// + official title in the header row underneath it.
struct ROMDetailView: View {
    let rom: ROMFile

    private let thumbnail: UIImage?
    private let saveStates: [NDSSaveStateSlotInfo]

    init(rom: ROMFile) {
        self.rom = rom
        self.thumbnail = ThumbnailManager.thumbnail(baseName: rom.baseName)
        self.saveStates = NDSSaveStatePaths.slotInfos(forBaseName: rom.baseName)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroView
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(alignment: .top, spacing: 12) {
                ROMIconView(rom: rom, cornerRadius: 10)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rom.banner?.englishTitle ?? rom.displayName)
                        .font(.headline)
                        .lineLimit(3)
                    Text((rom.filename as NSString).deletingPathExtension)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statItem(icon: "doc.zipper", label: "Size", value: rom.formattedFileSize)
                statItem(icon: "calendar", label: "Added", value: Self.dateFormatter.string(from: rom.creationDate))
                statItem(icon: "number", label: "Game Code", value: rom.gameCode)
                statItem(icon: "internaldrive",
                         label: "Battery Save",
                         value: rom.hasSaveFile
                            ? NSLocalizedString("Present", comment: "ROM preview stat value: a battery save file exists")
                            : NSLocalizedString("None", comment: "ROM preview stat value: no battery save file exists"))
            }

            if !saveStates.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save States")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(saveStates) { slot in
                        saveStateRow(slot)
                    }
                }
            }

            playAffordance
        }
        .padding()
        .frame(width: 320)
    }

    @ViewBuilder
    private var heroView: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.20, green: 0.20, blue: 0.26), Color(red: 0.09, green: 0.09, blue: 0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                ROMIconView(rom: rom, cornerRadius: 8)
                    .frame(width: 72, height: 72)
                    .opacity(0.9)
            }
        }
    }

    /// `label` is a `LocalizedStringKey` so the literals at the call sites
    /// localize; `value` stays a `String` because it is mostly runtime data
    /// (file size, date, game code) — call sites localize it when it isn't.
    private func statItem(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func saveStateRow(_ slot: NDSSaveStateSlotInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: slot.isAuto ? "clock.arrow.circlepath" : "square.stack.3d.up.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text(slot.isAuto ? "Auto-Save" : "Slot \(slot.slot + 1)")
                .font(.caption2)
            Spacer(minLength: 0)
            if let date = slot.modifiedDate {
                Text(Self.dateFormatter.string(from: date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playAffordance: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
            Text("Play")
                .font(.subheadline.bold())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
