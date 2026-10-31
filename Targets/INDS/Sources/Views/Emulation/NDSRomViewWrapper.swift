import SwiftUI

struct NDSRomViewWrapper: UIViewControllerRepresentable {
    let rom: ROMFile
    let chrome: NDSGameChrome
    var onQuitToLibrary: () -> Void

    func makeUIViewController(context: Context) -> NDSRomViewController {
        let controller = NDSRomViewController(rom: rom)
        controller.onQuitToLibrary = onQuitToLibrary
        controller.chrome = chrome
        return controller
    }

    func updateUIViewController(_ uiViewController: NDSRomViewController, context: Context) {
        uiViewController.update(rom: rom)
        uiViewController.onQuitToLibrary = onQuitToLibrary
    }

    static func dismantleUIViewController(_ uiViewController: NDSRomViewController, coordinator: ()) {
        uiViewController.stopForTeardown()
    }
}
