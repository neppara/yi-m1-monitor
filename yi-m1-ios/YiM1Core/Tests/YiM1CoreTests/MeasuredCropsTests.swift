import XCTest
@testable import YiM1Core

final class MeasuredCropsTests: XCTestCase {
    func testVideoPrefixMatching() {
        XCTAssertEqual(MeasuredCrops.videoCrop(forFormat: "4K_30"), CropRect(0.1294, 0.2230, 0.7409, 0.5558))
        XCTAssertEqual(MeasuredCrops.videoCrop(forFormat: "4K_24"), CropRect(0.1294, 0.2230, 0.7409, 0.5558)) // prefix match, not exact string
        XCTAssertEqual(MeasuredCrops.videoCrop(forFormat: "FHD_30"), CropRect(0.0004, 0.1268, 0.9961, 0.7472))
        XCTAssertEqual(MeasuredCrops.videoCrop(forFormat: "2K_30"), CropRect(0, 0, 1, 1))
    }

    func testVideoUnknownFormatReturnsNil() {
        XCTAssertNil(MeasuredCrops.videoCrop(forFormat: "HD_60"))
        XCTAssertNil(MeasuredCrops.videoCrop(forFormat: nil))
    }

    func testPhotoExactMatching() {
        XCTAssertEqual(MeasuredCrops.photoCrop(forAspect: "16:9"), CropRect(0.0000, 0.1247, 1.0000, 0.7510))
        XCTAssertEqual(MeasuredCrops.photoCrop(forAspect: "4:3"), CropRect(0, 0, 1, 1))
        XCTAssertNil(MeasuredCrops.photoCrop(forAspect: "21:9"))
        XCTAssertNil(MeasuredCrops.photoCrop(forAspect: nil))
    }
}
