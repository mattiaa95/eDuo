//
//  NDSClipRecorder.swift
//  eDuo
//
//  New (no iGBA equivalent). Thin ObservableObject wrapper around
//  RPScreenRecorder for the pause menu's "Record Clip" row: `isRecording`
//  drives the row's live label/icon via `@ObservedObject` even while the
//  pause menu sheet stays open across the async start/stop round-trip (the
//  row never dismisses the sheet, same as Save State). `onRecordingStateChanged`
//  is the same fact mirrored as a plain closure for `NDSRomViewController`
//  (UIKit, no `@ObservedObject`) to drive the HUD's REC badge. Ungated — free
//  for everyone, unlike Cheats/Speed/Filter.
//

import Foundation
import ReplayKit

final class NDSClipRecorder: ObservableObject {
    @Published private(set) var isRecording = false {
        didSet { onRecordingStateChanged?(isRecording) }
    }

    /// Non-nil after a failed start — the pause menu's row surfaces this as
    /// a simple alert, then clears it back to nil on dismiss.
    @Published var lastErrorMessage: String?

    /// Imperative mirror of `isRecording`, for the HUD's REC badge
    /// (NDSHUDView/NDSRomViewController — plain UIKit, no `@ObservedObject`).
    var onRecordingStateChanged: ((Bool) -> Void)?

    /// False when ReplayKit itself can't record right now (e.g. an active
    /// AirPlay/mirroring session, or an MDM restriction) — the pause menu
    /// hides the "Record Clip" row entirely rather than showing one that
    /// would always fail.
    var isAvailable: Bool { RPScreenRecorder.shared().isAvailable }

    /// Starts if idle, stops if already recording. `onPreview` fires with a
    /// ready-to-present `RPPreviewViewController` once a recording actually
    /// stops with something to show — presenting it is the caller's job
    /// (it needs a UIViewController), this type only touches RPScreenRecorder.
    func toggle(onPreview: @escaping (RPPreviewViewController) -> Void) {
        if isRecording {
            stop(onPreview: onPreview)
        } else {
            start()
        }
    }

    private func start() {
        let recorder = RPScreenRecorder.shared()
        // Game audio is captured regardless; this only controls the device's
        // physical mic, which would otherwise trigger an unexpected
        // microphone-permission prompt for a plain "record my gameplay" tap.
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                    return
                }
                self.isRecording = true
            }
        }
    }

    private func stop(onPreview: @escaping (RPPreviewViewController) -> Void) {
        RPScreenRecorder.shared().stopRecording { [weak self] preview, error in
            DispatchQueue.main.async {
                self?.isRecording = false
                if let error {
                    self?.lastErrorMessage = error.localizedDescription
                    return
                }
                if let preview {
                    onPreview(preview)
                }
            }
        }
    }

    /// Best-effort, fire-and-forget stop with no preview — used when the
    /// game session ends (quit, or the plain swipe-back teardown path) while
    /// a clip is mid-recording, so it never keeps recording behind a
    /// torn-down screen. No-op if nothing is recording.
    func stopIfNeeded() {
        guard isRecording else { return }
        isRecording = false
        RPScreenRecorder.shared().stopRecording { _, error in
            if let error {
                debugLog("Clip recording teardown stop failed: \(error.localizedDescription)")
            }
        }
    }
}
