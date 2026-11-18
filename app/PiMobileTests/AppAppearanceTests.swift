import XCTest
import SwiftUI
@testable import PiMobile

final class AppAppearanceTests: XCTestCase {
    func testFontScaleClampsPersistedOutOfRangeValues() {
        XCTAssertEqual(AppFontScale.normalized(-4), 0.8)
        XCTAssertEqual(AppFontScale.normalized(0.8), 0.8)
        XCTAssertEqual(AppFontScale.normalized(1.15), 1.15)
        XCTAssertEqual(AppFontScale.normalized(1.5), 1.5)
        XCTAssertEqual(AppFontScale.normalized(10), 1.5)
    }

    func testInvalidPersistedFontScaleFallsBackToStandardSize() {
        XCTAssertEqual(AppFontScale.normalized(.nan), 1)
        XCTAssertEqual(AppFontScale.normalized(.infinity), 1)
        XCTAssertEqual(AppFontScale.normalized(-.infinity), 1)
    }

    func testFollowingSystemTemporarilyIgnoresCustomFontScale() {
        XCTAssertEqual(AppFontScale.effective(1.4, followsSystem: true), 1)
        XCTAssertEqual(AppFontScale.effective(.nan, followsSystem: true), 1)
        XCTAssertEqual(AppFontScale.effective(1.4, followsSystem: false), 1.4)
        XCTAssertEqual(AppFontScale.effective(4, followsSystem: false), 1.5)
    }

    func testPersistedInterfaceStylesResolveToSystemOrExplicitAppearance() {
        XCTAssertNil(PiInterfaceStyle(rawValue: "system")?.colorScheme)
        XCTAssertEqual(PiInterfaceStyle(rawValue: "light")?.colorScheme, .light)
        XCTAssertEqual(PiInterfaceStyle(rawValue: "dark")?.colorScheme, .dark)
    }
}
