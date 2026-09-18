import XCTest
@testable import InventoryCore

final class MediaPresentationTests: XCTestCase {
    func testVideoDurationFormatting() {
        let cases: [(TimeInterval, String)] = [
            (0, "0:00"), (8, "0:08"), (59, "0:59"), (60, "1:00"),
            (134, "2:14"), (3599, "59:59"), (3600, "1:00:00"), (3737, "1:02:17"),
            (-4, "0:00")
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(MediaPresentation.durationString(seconds), expected)
        }
    }

    func testAudioIsRetainedInternallyButNotVisible() {
        XCTAssertTrue(MediaPresentation.isVisibleMediaType("image"))
        XCTAssertTrue(MediaPresentation.isVisibleMediaType("video"))
        XCTAssertFalse(MediaPresentation.isVisibleMediaType("audio"))
    }

    func testMixedMediaCounts() {
        let counts = MediaPresentation.counts(Array(repeating: "image", count: 5)
            + Array(repeating: "video", count: 3)
            + Array(repeating: "audio", count: 2))
        XCTAssertEqual(counts.images, 5)
        XCTAssertEqual(counts.videos, 3)
        XCTAssertEqual(counts.audio, 2)
        XCTAssertEqual(counts.visible, 8)
    }
}
