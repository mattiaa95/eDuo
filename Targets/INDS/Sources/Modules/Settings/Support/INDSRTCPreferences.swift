//
//  INDSRTCPreferences.swift
//  eDuo
//
//  Settings > Date & Time. The DS has its own real-time clock, and melonDS
//  boots it at 2000-01-01 00:00:00 unless the frontend seeds it — eDuo never
//  did, so every game that reads the date/time (life sims, day/night
//  cycles, berry growth, daily events) has been living in the year 2000.
//
//  Stored as an OFFSET from the device clock rather than an absolute date,
//  the same shape as melonDS's own `RTC.Offset`: the console clock then keeps
//  ticking on its own instead of freezing at whatever instant was picked, so
//  "one hour ahead" or "back in 2007" stay true tomorrow as well.
//

import Foundation

enum INDSRTCPreferences {
    private static let syncKey = "eNDSClockSyncToDevice"
    private static let offsetKey = "eNDSClockOffsetSeconds"

    /// Default on: the device clock is what almost everyone wants, and it is
    /// what the console would have had.
    static var syncToDeviceClock: Bool {
        get {
            if UserDefaults.standard.object(forKey: syncKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: syncKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: syncKey) }
    }

    /// Seconds added to the device clock when `syncToDeviceClock` is off.
    static var offsetSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: offsetKey) }
        set { UserDefaults.standard.set(newValue, forKey: offsetKey) }
    }

    /// What the console's clock should read right now.
    static var consoleDate: Date {
        syncToDeviceClock ? Date() : Date().addingTimeInterval(offsetSeconds)
    }

    /// Stores `date` as the console time for this instant, as an offset.
    static func setConsoleDate(_ date: Date) {
        offsetSeconds = date.timeIntervalSinceNow
        syncToDeviceClock = false
    }

    /// The DS RTC holds a two-digit year: 2000-2099. Outside that the console
    /// simply cannot represent the date, so clamp rather than wrap silently.
    static func clamped(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let lower = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? date
        let upper = calendar.date(from: DateComponents(year: 2099, month: 12, day: 31, hour: 23, minute: 59, second: 59)) ?? date
        return min(max(date, lower), upper)
    }

    /// Date components the core wants, in the device's own calendar. Swift
    /// imports the bridge's `NSDateComponents *` parameter as this value
    /// type, so hand it exactly that.
    static func componentsForCore() -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                       from: clamped(consoleDate))
    }
}
