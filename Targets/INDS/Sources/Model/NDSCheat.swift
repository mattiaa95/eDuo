//
//  NDSCheat.swift
//  eDuo
//
//  New (no iGBA equivalent — GBA cheats are a different, simpler format).
//  Swift-side model + on-disk persistence for melonDS Action Replay codes.
//  There is no separate database: the on-disk `.mch` file *is* the model
//  (per-cheat `enabled` included), written in melonDS's own ARCodeFile text
//  format (see Vendor/melonDS/src/ARCodeFile.cpp Load/Save) so it stays
//  loadable by `-[MelonDSCoreBridge reloadCheatsFromFile:enabled:]` — and,
//  if anyone ever pulled it out, by upstream melonDS itself.
//

import Foundation

/// One Action Replay code as edited in the Cheats sheet. `code` is the raw
/// multi-line "AAAAAAAA VVVVVVVV" textarea contents exactly as the user
/// typed them — only split/validated into individual hex-pair lines when
/// persisting to disk (`NDSCheatFileStore`) or checking validity
/// (`NDSCheatValidation`).
struct NDSCheat: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var code: String
    var enabled: Bool
}

enum NDSCheatValidation {
    private static let hexDigits = Set("0123456789abcdefABCDEF")

    /// `code`'s non-blank lines, trimmed. Blank lines are just spacing and
    /// are dropped, not treated as errors. Split on *any* newline, not just
    /// `\n`: a code list pasted from a web page or a note arrives with CRLF
    /// (or a lone CR, or U+2028) at least as often as with a bare LF, and a
    /// stray `\r` left at the end of a line is invisible in the editor but
    /// makes the line fail every check below.
    static func codeLines(_ code: String) -> [String] {
        code
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One data line in melonDS's own canonical form — `"AAAAAAAA VVVVVVVV"`,
    /// uppercase, exactly one space — or nil if it isn't a code line at all.
    ///
    /// Deliberately liberal about the input: published AR lists separate the
    /// two words with a tab, several spaces or a non-breaking space, or run
    /// them together as 16 hex digits. All of those are the same code, so all
    /// of them are accepted — but only ever written out in the one shape
    /// `ARCodeFile::Load`'s `sscanf(line, "%08X %08X", ...)` accepts, and only
    /// with ASCII hex digits (`Character.isHexDigit` would also say yes to
    /// full-width forms, which survive `uppercased()` and would then fail that
    /// `sscanf`). The word lengths are checked as 8 + 8 rather than just
    /// "16 hex in total" so a typo like `023FE0 0000000063` is rejected
    /// instead of silently becoming a write to a different address.
    static func normalizedLine(_ line: String) -> String? {
        let words = line.split(whereSeparator: \.isWhitespace)
        let hex: String
        switch words.count {
        case 1 where words[0].count == 16: hex = String(words[0])
        case 2 where words[0].count == 8 && words[1].count == 8: hex = words.joined()
        default: return nil
        }
        guard hex.allSatisfy(hexDigits.contains) else { return nil }
        let upper = hex.uppercased()
        return "\(upper.prefix(8)) \(upper.suffix(8))"
    }

    /// The data lines of `code` exactly as melonDS should run them, with
    /// anything that isn't a code line dropped. This is what gets written
    /// to disk: `ARCodeFile::Load` bails out on the *first* malformed data
    /// line and reports the whole file as an error, so one bad line in one
    /// cheat would silently kill every cheat for that game.
    ///
    /// A CodeBreaker/CodeFreak code comes back translated to Action Replay
    /// (see `NDSCodeBreaker`); one the translator can't handle comes back
    /// as typed, and `isValid` is false for it so it is never enabled.
    static func normalizedLines(_ code: String) -> [String] {
        let lines = codeLines(code).compactMap(normalizedLine)
        if let translated = try? NDSCodeBreaker.translate(lines.map(pair)) {
            return translated.map(NDSCodeBreaker.text)
        }
        return lines
    }

    static func isValidLine(_ line: String) -> Bool {
        normalizedLine(line) != nil
    }

    enum CodeFormat: Equatable {
        case actionReplay
        case codeBreaker
        case codeBreakerUnsupported
    }

    /// What `code` is, for the editor to say so. nil when it is empty or
    /// has a line that isn't a hex pair at all.
    static func format(of code: String) -> CodeFormat? {
        let lines = codeLines(code)
        guard !lines.isEmpty else { return nil }
        var pairs: [NDSCodeBreaker.Line] = []
        for line in lines {
            guard let canonical = normalizedLine(line) else { return nil }
            pairs.append(pair(canonical))
        }
        do {
            return try NDSCodeBreaker.translate(pairs) == nil ? .actionReplay : .codeBreaker
        } catch {
            return .codeBreakerUnsupported
        }
    }

    /// True only if every non-blank line is a valid hex pair, the code is
    /// something the engine can run (Action Replay, or CodeBreaker the
    /// translator handles) *and* at least one runnable line results. An
    /// empty/all-invalid code must never be persisted as `enabled`:
    /// melonDS's `AREngine::RunCheat` indexes `Code[Code.size() - 1]`
    /// unconditionally, which is undefined behavior for a zero-length code
    /// — the exact shape of iGBA's own historical P0 cheats crash. This
    /// guard is checked independently at every layer (the toggle in
    /// `NDSCheatsView`, serialization here, and the bridge's own filter in
    /// `-reloadCheatsFromFile:enabled:`) — belt and suspenders.
    static func isValid(_ code: String) -> Bool {
        guard let format = format(of: code), format != .codeBreakerUnsupported else { return false }
        return !normalizedLines(code).isEmpty
    }

    /// `canonical` is a `normalizedLine` result, so both words parse.
    private static func pair(_ canonical: String) -> NDSCodeBreaker.Line {
        (UInt32(canonical.prefix(8), radix: 16) ?? 0, UInt32(canonical.suffix(8), radix: 16) ?? 0)
    }
}

/// Reads/writes a game's cheat list as melonDS's own `.mch` ARCodeFile text
/// format, always as a flat "ROOT" list (no categories — this app's Cheats
/// sheet is a single flat list per game).
enum NDSCheatFileStore {
    /// `Documents/Saves/<baseName>.mch` — same directory as the battery save
    /// (`ROMFile.saveFileURL`'s `Documents/Saves/<baseName>.sav` convention,
    /// mirroring `MelonDSCoreBridge`'s own `loadROMAtPath:`), melonDS's own
    /// cheat-file extension (melonDS's Qt frontend, EmuInstance.cpp
    /// `loadCheats`: `getAssetPath(..., ".mch")`).
    static func fileURL(forBaseName baseName: String) -> URL? {
        guard !baseName.isEmpty, let dir = try? ROMStorageManager.savesDirectoryURL() else { return nil }
        return dir.appendingPathComponent(baseName).appendingPathExtension("mch")
    }

    /// Empty if `baseName` has no cheat file yet, or it doesn't parse —
    /// never throws, matching `ARCodeFile::Load` treating a missing file as
    /// a normal, error-free empty list rather than a failure.
    static func load(forBaseName baseName: String) -> [NDSCheat] {
        guard let url = fileURL(forBaseName: baseName),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Overwrites the whole file with `cheats`. Best-effort (a write
    /// failure — e.g. disk full — just leaves the previous on-disk version
    /// in place; there's nothing actionable for the user to do about it).
    static func save(_ cheats: [NDSCheat], forBaseName baseName: String) {
        guard let url = fileURL(forBaseName: baseName) else { return }
        try? serialize(cheats).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rewrites the file in the form `serialize` produces today, if it
    /// differs. Called before the file is handed to the core: a cheat list
    /// saved by an earlier version may hold CodeBreaker/CodeFreak codes as
    /// typed (they were accepted, stored and run as Action Replay — doing
    /// nothing), and this is what turns them into the working translation
    /// without the user having to open the sheet and re-save.
    static func migrateIfNeeded(forBaseName baseName: String) {
        guard let url = fileURL(forBaseName: baseName),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let fresh = serialize(parse(text))
        guard fresh != text else { return }
        try? fresh.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - melonDS ARCodeFile text format

    private static func serialize(_ cheats: [NDSCheat]) -> String {
        var text = "ROOT\n\n"
        for cheat in cheats {
            let lines = NDSCheatValidation.normalizedLines(cheat.code)
            // Same empty-code guard as -reloadCheatsFromFile:enabled: below
            // — never write a code as enabled if it has no valid lines, or
            // if it is a CodeBreaker code the translator couldn't handle
            // (run as Action Replay it would write garbage).
            let enabled = cheat.enabled && !lines.isEmpty && NDSCheatValidation.isValid(cheat.code)
            let name = cheat.name
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            text += "CODE \(enabled ? 1 : 0) \(name)\n"
            for line in lines {
                text += "\(line)\n"
            }
            text += "\n"
        }
        return text
    }

    /// Deliberately lenient: unrecognized lines (a foreign file's CAT/DESC,
    /// stray text, ...) are just skipped rather than failing the whole parse
    /// — this only ever needs to round-trip what `serialize(_:)` itself
    /// wrote, and must never crash/throw on a hand-edited file.
    private static func parse(_ text: String) -> [NDSCheat] {
        var cheats: [NDSCheat] = []
        var pendingName: String?
        var pendingEnabled = false
        var pendingLines: [String] = []

        func flush() {
            guard let name = pendingName else { return }
            cheats.append(NDSCheat(name: name, code: pendingLines.joined(separator: "\n"), enabled: pendingEnabled))
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CODE ") {
                flush()
                pendingLines = []
                let rest = line.dropFirst("CODE ".count)
                if let spaceIndex = rest.firstIndex(of: " ") {
                    pendingEnabled = rest[rest.startIndex..<spaceIndex] == "1"
                    pendingName = String(rest[rest.index(after: spaceIndex)...])
                } else {
                    pendingEnabled = false
                    pendingName = rest.isEmpty ? nil : String(rest)
                }
            } else if let dataLine = NDSCheatValidation.normalizedLine(line) {
                pendingLines.append(dataLine)
            }
            // ROOT / CAT / DESC / blank / garbage: ignored.
        }
        flush()

        return cheats
    }
}
