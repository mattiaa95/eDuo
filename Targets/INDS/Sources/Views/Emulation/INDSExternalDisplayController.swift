//
//  INDSExternalDisplayController.swift
//  eDuo
//
//  External display / AirPlay screen mirroring: when a second screen is
//  present, it takes over showing the Top screen fullscreen (letterboxed
//  over the Game Background color), freeing the device to become the touch
//  screen + controls (see `NDSRomViewController.applyCurrentScreenLayout`).
//
//  Scene-based on purpose. The first shipped attempt used the legacy
//  `UIScreen.didConnectNotification` + `UIWindow(frame:)`/`window.screen =`
//  route — in this app (SwiftUI `App` lifecycle, scene-based) UIKit never
//  rendered that window, so with "Screen Mirroring" active the TV just kept
//  mirroring the phone while the phone had already collapsed to the touch
//  screen: the top screen was visible NOWHERE (the exact on-device bug this
//  rewrite fixes). Scene-based apps must claim external displays through a
//  `UIWindowScene` with the `.windowExternalDisplayNonInteractive` role,
//  which UIKit connects automatically while mirroring/HDMI is active —
//  `AppDelegate.application(_:configurationForConnecting:options:)` routes
//  that role to `INDSExternalSceneDelegate` below.
//
//  The simulator CAN exercise this one (I/O > External Displays), unlike the
//  legacy path which also needed a real AirPlay target to disprove.
//
import UIKit

final class INDSExternalDisplayController {
    static let shared = INDSExternalDisplayController()

    private(set) var isConnected = false

    /// Fires right after `isConnected` changes, so `NDSRomViewController`
    /// can re-apply its on-device layout without polling.
    var onConnectionChanged: ((Bool) -> Void)?

    fileprivate var imageView: UIImageView?

    private init() {}

    fileprivate func sceneDidAttach(imageView: UIImageView) {
        self.imageView = imageView
        isConnected = true
        onConnectionChanged?(true)
    }

    fileprivate func sceneDidDetach() {
        imageView = nil
        isConnected = false
        onConnectionChanged?(false)
    }

    /// Called once per presented frame by `NDSRomViewController`, right
    /// alongside its own on-device framebuffer copy — a cheap no-op
    /// whenever no external display is connected.
    func present(topImage: UIImage?) {
        imageView?.image = topImage
    }
}

/// Scene delegate for the `.windowExternalDisplayNonInteractive` role only —
/// never the on-device scene (SwiftUI owns that one). UIKit connects this
/// scene automatically whenever an external display is available while the
/// app is foreground, and disconnects it when mirroring/HDMI ends.
final class INDSExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = INDSAppearanceStore.shared.gameBackgroundUIColor

        let contentViewController = UIViewController()
        contentViewController.view.backgroundColor = .clear
        window.rootViewController = contentViewController

        let imageView = UIImageView(frame: contentViewController.view.bounds)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit // letterboxed, never cropped/stretched
        // DS framebuffers are 256x192 — pixel-crisp upscaling reads far
        // better on a TV than the default bilinear blur.
        imageView.layer.magnificationFilter = .nearest
        imageView.backgroundColor = .clear
        contentViewController.view.addSubview(imageView)

        window.isHidden = false
        self.window = window

        INDSExternalDisplayController.shared.sceneDidAttach(imageView: imageView)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window?.isHidden = true
        window = nil
        INDSExternalDisplayController.shared.sceneDidDetach()
    }
}
