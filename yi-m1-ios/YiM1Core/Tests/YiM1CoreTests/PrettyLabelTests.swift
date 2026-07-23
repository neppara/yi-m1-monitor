import XCTest
@testable import YiM1Core

final class PrettyLabelTests: XCTestCase {
    // Ported directly from the Python display-label test performed live during the macOS
    // session (2026-07-07) - same expected outputs, so this doc'd behavioral parity is checked
    // by an automated test instead of only a one-off manual script.
    func testKnownMappings() {
        let cases: [(SettingKey, String, String)] = [
            (.iso, Iso.i200.rawValue, "200"),
            (.shutterSpeed, ShutterSpeed.sf100.rawValue, "1/100s"),
            (.fNumber, FStop.f1_4.rawValue, "f/1.4"),
            (.ev, EvOffset.n5_0.rawValue, "-5.0"),
            (.ev, EvOffset.p2_0.rawValue, "+2.0"),
            (.ev, EvOffset.zero.rawValue, "0.0"),
            (.ev, EvOffset.p0_3.rawValue, "0.3"), // starts with "0" - no "+" prefix, matches Python quirk exactly
            (.imageQuality, ImageQuality.mp50Interpolated.rawValue, "50 MP"),
            (.imageQuality, ImageQuality.vga.rawValue, "VGA"),
            (.meteringMode, MeteringMode.centerWeighted.rawValue, "Center"),
            (.colorMode, ColorStyle.naturalBW.rawValue, "B&W soft"),
            (.whiteBalance, WhiteBalance.k5000.rawValue, "5000K"),
            (.whiteBalance, WhiteBalance.auto.rawValue, "Auto"),
            (.fileFormat, FileFormat.rawAndJpegLarge.rawValue, "RAW+L"),
            (.driveMode, DriveMode.delay2s.rawValue, "2s timer"),
            (.exposureMode, ExposureMode.aperturePriority.rawValue, "Aperture"),
            (.focusMode, FocusMode.manualFocus.rawValue, "Manual"),
            (.imageAspect, ImageAspect.widescreen.rawValue, "16:9"), // no rule - passthrough
        ]
        for (key, raw, expected) in cases {
            XCTAssertEqual(PrettyLabel.prettyLabel(for: key, rawValue: raw), expected, "\(key) / \(raw)")
        }
    }

    func testDisplayLabelPropertyMatchesHelper() {
        XCTAssertEqual(Iso.i800.displayLabel, PrettyLabel.prettyLabel(for: .iso, rawValue: "800"))
        XCTAssertEqual(FStop.f2_8.displayLabel, "f/2.8")
    }
}
