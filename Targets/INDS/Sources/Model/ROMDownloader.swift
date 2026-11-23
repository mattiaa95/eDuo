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
        case unreachable
        case notAFile

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return String(format: NSLocalizedString("The download failed (HTTP %d).", comment: "Download error: HTTP status code"), code)
            case .invalidLink:
                return NSLocalizedString("That is not a valid web link.", comment: "Download from link: invalid URL")
            case .unreachable:
                return NSLocalizedString("Couldn't download the game. Check the internet connection and try again. You can also add a game from a file: tap + then Import from Files.", comment: "Download error: network failure after retries; points to the offline route")
            case .notAFile:
                return NSLocalizedString("The link did not return a game file (a network login page or filter may be in the way). Tap + then Import from Files to add a game from a file instead.", comment: "Download error: the server answered with a web page instead of a file")
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

    /// Own session: 20 s without data gives up (the shared one waits 60 s), and
    /// a flaky first connection (GitHub's release redirect goes to a second
    /// host) gets two more tries before the user sees an error.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// Downloads `url` and returns a file URL named after the original file.
    /// Retries network errors and 5xx up to 3 times; never retries a 4xx.
    static func download(_ url: URL, attempts: Int = 3, session: URLSession = ROMDownloader.session) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.invalidLink
        }
        var lastError: Error = DownloadError.unreachable
        for attempt in 1...max(1, attempts) {
            do {
                return try await downloadOnce(url, session: session)
            } catch let error as DownloadError {
                if case .http(let code) = error, code >= 500 { lastError = error } else { throw error }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = DownloadError.unreachable
                debugLog("ROMDownloader attempt \(attempt) failed: \(error.localizedDescription)")
            }
            if attempt < attempts { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
        }
        throw lastError
    }

    private static func downloadOnce(_ url: URL, session: URLSession) async throws -> URL {
        let (tempURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode)
        }
        // A proxy or captive portal answers 200 with a login page; saved as
        // `jamclown.nds` it would pass the import's header check.
        if (response.mimeType ?? "").lowercased() == "text/html" { throw DownloadError.notAFile }
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
