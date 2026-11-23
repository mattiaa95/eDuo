import XCTest
@testable import eNDS

/// Per-title texture sampling override (Super Robot Wars BX -> Nearest unless the user chose).
final class ThreeDSSamplingOverrideTests: XCTestCase {
    private let srwbx: UInt64 = 0x0004000000127900

    func testDefaultTakesOverrideForListedTitle() {
        XCTAssertEqual(ThreeDSScreenPrefs.effectiveSampling(titleID: srwbx, pref: 0), 1)
    }

    func testExplicitChoiceIsRespected() {
        XCTAssertEqual(ThreeDSScreenPrefs.effectiveSampling(titleID: srwbx, pref: 2), 2)
        XCTAssertEqual(ThreeDSScreenPrefs.effectiveSampling(titleID: srwbx, pref: 1), 1)
    }

    func testOtherTitlesKeepTheirSetting() {
        XCTAssertEqual(ThreeDSScreenPrefs.effectiveSampling(titleID: 0x0004000000000001, pref: 0), 0)
        XCTAssertEqual(ThreeDSScreenPrefs.effectiveSampling(titleID: 0x0004000000000001, pref: 2), 2)
    }
}
