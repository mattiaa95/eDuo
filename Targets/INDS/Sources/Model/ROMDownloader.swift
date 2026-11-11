import Foundation

/// In-app "get a game": downloads a file the user (or the demo menu) points
/// at into a fresh temp folder, so the normal `ROMStorageManager.importAny`
/// path can take it from there — no Files/Safari round trip needed.
enum ROMDownloader {
    /// Free open-source homebrew (MIT) for the demo menu / empty state.
    static let jamClown = URL(string: "https://github.com/lorenzolanglois/JamClown/releases/download/v1.0/jamclown.nds")!
    static let game2048 = URL(string: "https://github.com/0rientd/2048-port-3ds/releases/download/v1.1.1/2048-port-3ds.3dsx")!

    enum DownloadError: LocalizedError {
        case http(Int)
        case invalidLink

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return String(format: NSLocalizedString("The download failed (HTTP %d).", comment: "Download error: HTTP status code"), code)
            case .invalidLink:
                return NSLocalizedString("That is not a valid web link.", comment: "Download from link: invalid URL")
            }
        }
    }

    /// Parses a user-typed link: trims spaces, prepends `https://` when the
    /// scheme is missing, accepts only http/https.
    static func parseLink(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Downloads `url` and returns a file URL named after the original file.
    static func download(_ url: URL) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.invalidLink
        }
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode)
        }
        var name = response.suggestedFilename ?? ""
        if (name as NSString).pathExtension.isEmpty { name = url.lastPathComponent }
        if name.isEmpty || name == "/" { name = "download" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}
