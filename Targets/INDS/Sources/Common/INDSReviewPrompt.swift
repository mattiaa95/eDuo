//
//  INDSReviewPrompt.swift
//  eDuo
//
//  When to ask for a rating without becoming a nuisance.
//
//  The button in Settings › About opens the review page directly, because
//  someone who taps it came for exactly that. This is the opposite: the
//  prompt nobody asked for, which is why it goes through
//  `SKStoreReviewController` — iOS caps that at roughly three times a year
//  and may decide to show nothing at all. That cap is a feature, not a
//  problem: all that is decided here is whether asking is *worth it*.
//
//  It asks on the way back to the library after a decent session — never
//  mid-game, which is where it annoys and where people tap three stars just
//  to get rid of it.
//

import Foundation
import StoreKit
import UIKit

enum INDSReviewPrompt {
    private enum Keys {
        static let sessions = "eNDSReviewSessions"
        static let playTime = "eNDSReviewPlayTime"
        static let lastAsked = "eNDSReviewLastAsked"
    }

    /// Three days, three sessions and twenty minutes played. Below that
    /// nobody has formed an opinion of an emulator yet, and asking earlier is
    /// how one-star ratings are harvested.
    private static let minDaysInstalled: TimeInterval = 3 * 24 * 3600
    private static let minSessions = 3
    private static let minPlayTime: TimeInterval = 20 * 60
    private static let minSecondsBetweenAsks: TimeInterval = 60 * 24 * 3600

    /// A session under a minute is open-and-close: it counts neither as a
    /// session nor as time played.
    private static let minSessionLength: TimeInterval = 60

    static func recordSession(playedFor seconds: TimeInterval) {
        guard seconds >= minSessionLength else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Keys.sessions) + 1, forKey: Keys.sessions)
        defaults.set(defaults.double(forKey: Keys.playTime) + seconds, forKey: Keys.playTime)
    }

    /// The decision, kept apart from the state. The failure to fear here is
    /// the silent one — never asking — and without this split there is no way
    /// to test for it without dirtying the real UserDefaults.
    static func shouldAsk(sessions: Int, playTime: TimeInterval,
                          installedFor: TimeInterval, sinceLastAsk: TimeInterval?) -> Bool {
        guard sessions >= minSessions,
              playTime >= minPlayTime,
              installedFor >= minDaysInstalled else { return false }
        if let sinceLastAsk, sinceLastAsk < minSecondsBetweenAsks { return false }
        return true
    }

    /// Call on the way back to the library. Returns without doing anything
    /// if it is not time yet; there is no return value because iOS does not
    /// say whether it showed anything either.
    @MainActor
    static func askIfEarned() {
        let defaults = UserDefaults.standard
        guard let firstLaunch = INDSHoneymoon.firstLaunchDate else { return }
        let last = defaults.object(forKey: Keys.lastAsked) as? Date
        guard shouldAsk(sessions: defaults.integer(forKey: Keys.sessions),
                        playTime: defaults.double(forKey: Keys.playTime),
                        installedFor: Date().timeIntervalSince(firstLaunch),
                        sinceLastAsk: last.map { Date().timeIntervalSince($0) }) else { return }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        // The date is recorded even if iOS decides not to show the prompt:
        // there is no way to tell, and retrying every time a game is closed
        // would be exactly the pestering this exists to avoid.
        defaults.set(Date(), forKey: Keys.lastAsked)
        AppStore.requestReview(in: scene)
    }

#if DEBUG
    /// Runs by itself at launch in Debug. The failure it watches for is the
    /// invisible one: thresholds set so the prompt never appears at all.
    static func selfCheck() {
        let day: TimeInterval = 24 * 3600
        let ok = shouldAsk(sessions: 3, playTime: 20 * 60, installedFor: 3 * day, sinceLastAsk: nil)
        assert(ok, "exactly at the minimums it must still ask")
        assert(!shouldAsk(sessions: 2, playTime: 60 * 60, installedFor: 30 * day, sinceLastAsk: nil))
        assert(!shouldAsk(sessions: 9, playTime: 60, installedFor: 30 * day, sinceLastAsk: nil))
        assert(!shouldAsk(sessions: 9, playTime: 60 * 60, installedFor: day, sinceLastAsk: nil))
        // Asked recently: do not push.
        assert(!shouldAsk(sessions: 9, playTime: 60 * 60, installedFor: 30 * day, sinceLastAsk: day))
        assert(shouldAsk(sessions: 9, playTime: 60 * 60, installedFor: 30 * day, sinceLastAsk: 90 * day))
    }
#endif
}
