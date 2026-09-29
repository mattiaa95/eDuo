import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Records the install moment the 48h honeymoon is measured from,
        // and starts the transaction listener so offer-code / out-of-band
        // Pro grants activate without the user opening the paywall.
        INDSHoneymoon.recordFirstLaunchIfNeeded()
#if DEBUG
        // Swift has no static initializers like the loopback's C++ self
        // check, so this one is called by hand. It aborts in Debug if the
        // review-prompt thresholds break — the failure it watches for is
        // never asking, which goes unnoticed until the ratings are missing.
        INDSReviewPrompt.selfCheck()
        // On-demand geometry sweep (`-iNDSLayoutSweep`): validates the
        // default layouts against foldable/window sizes no current simulator
        // offers. Without the launch argument it does nothing.
        INDSLayoutSweep.runIfRequested()
        // The same thing, visually (`-iNDSVisualSweep`): renders the
        // emulation screen to PNG at foldable/iPad sizes and exits.
        INDSVisualSweep.runIfRequested()
#endif
        EntitlementManager.shared.startTransactionListener()
        EntitlementManager.shared.refreshEntitlementsAsync()

        // Before the first import can start, so it never races a live one.
        ROMStorageManager.removeStaleImportDirectories()

        if let url = launchOptions?[.url] as? URL {
            Self.handleFileURL(url)
        }
        return true
    }

    /// Refreshes StoreKit entitlements so offer-code redemptions made while
    /// the app was backgrounded (e.g. in the App Store) activate Pro
    /// automatically on return.
    func applicationWillEnterForeground(_ application: UIApplication) {
        EntitlementManager.shared.refreshEntitlementsAsync()
    }

    /// Routes ONLY the external-display role to our scene delegate (AirPlay
    /// mirroring / HDMI → the TV shows the Top screen, see
    /// INDSExternalDisplayController). Every other role falls through to a
    /// plain configuration so SwiftUI keeps owning the on-device scene.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = INDSExternalSceneDelegate.self
        }
        return configuration
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard url.isFileURL else { return false }
        Self.handleFileURL(url)
        return true
    }

    private static let supportedExternalExtensions: Set<String> = ["nds", "zip", "7z", "gz", "sav"]

    /// Routes a file opened externally ("Open in eDuo" from Files/Safari, or
    /// a plain double-tap on a `.nds`/`.zip`/`.7z`/`.sav`) through the same import
    /// dispatcher the in-app "+" picker uses.
    ///
    /// A duplicate `.nds` is replaced silently only when it is the same game
    /// (`ROMReplacePolicy.ifSameGame`: identical header and size). A different
    /// file under a known name — a hack, a randomizer output — goes through the
    /// same "Already Exists / Replace?" alert the in-app picker uses, and on
    /// confirmation the old save states are set aside rather than resumed into
    /// it. A duplicate `.sav` always asks: it would overwrite the live battery
    /// save, and someone double-tapping a `.sav` in Files to see what it is
    /// must not lose their progress for it.
    @MainActor
    static func handleFileURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard supportedExternalExtensions.contains(ext) else {
            debugLog("Ignoring unsupported external file: \(url.lastPathComponent)")
            return
        }
        // SwiftUI's `onOpenURL` and `application(_:open:)` can both fire for
        // one "Open in eDuo"; two concurrent imports of the same URL would
        // race on the security scope and on the destination file.
        guard inFlight.insert(url).inserted else { return }

        let isSave = (ext == "sav")
        Task.detached(priority: .userInitiated) {
            await importExternal(url, isSave: isSave)
            await MainActor.run { _ = inFlight.remove(url) }
        }
    }

    @MainActor private static var inFlight: Set<URL> = []

    private static func importExternal(_ url: URL, isSave: Bool) async {
        do {
            let outcome = try ROMStorageManager.importAny(from: url, replacePolicy: isSave ? .never : .ifSameGame)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .romImported,
                    object: nil,
                    userInfo: ["filenames": outcome.importedROMURLs.map { $0.lastPathComponent }]
                )
                if !outcome.failureMessages.isEmpty {
                    NotificationCenter.default.post(
                        name: .romImportFailed,
                        object: nil,
                        userInfo: ["message": outcome.failureMessages.joined(separator: "\n")]
                    )
                }
            }
        } catch ROMStorageError.duplicateFile {
            // A `.sav`, or a `.nds` that is not the same game as the one it
            // would replace. Stage a copy in tmp: the security-scoped grant on
            // `url` is tied to this open, and the user's answer can be seconds
            // away.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: staged)
            // `importAny` already closed its own scope; reopen it for the copy.
            let scoped = url.startAccessingSecurityScopedResource()
            let copied = (try? FileManager.default.copyItem(at: url, to: staged)) != nil
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard copied else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .romImportNeedsReplaceConfirm,
                    object: nil,
                    userInfo: ["url": staged]
                )
            }
        } catch {
            debugLog("External ROM import failed: \(error.localizedDescription)")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .romImportFailed,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }
    }
}
