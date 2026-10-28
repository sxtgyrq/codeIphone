import CoreGraphics
import XCTest
@testable import HelloYrq

final class MapTransformTests: XCTestCase {
    func testOneUnitSegmentsRemainDistinctAtMaximumZoomAcrossMap() {
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 17_000, y: 482_000),
                       CGPoint(x: 499_999, y: 499_999)] {
            let transform = MapTransform(center: origin, scale: MapTransform.maximumScale,
                                         size: CGSize(width: 375, height: 500))
            let start = transform.screen(origin)
            let horizontal = transform.screen(CGPoint(x: origin.x + 1, y: origin.y))
            let vertical = transform.screen(CGPoint(x: origin.x, y: origin.y + 1))
            XCTAssertEqual(horizontal.x - start.x, 128, accuracy: 0.000001)
            XCTAssertEqual(vertical.y - start.y, -128, accuracy: 0.000001)
            let restored = transform.world(horizontal)
            XCTAssertEqual(restored.x, origin.x + 1, accuracy: 0.000001)
            XCTAssertEqual(restored.y, origin.y, accuracy: 0.000001)
        }
    }

    func testGridShowsIntegerUnitAtDetailedZoomAndCoarsensForOverview() {
        let scales: [CGFloat] = [0.0001, 0.01, 1, 8, 32, 64, 72, 128]
        for scale in scales {
            let transform = MapTransform(center: .zero, scale: scale, size: CGSize(width: 375, height: 500))
            XCTAssertGreaterThanOrEqual(transform.gridStep, 1)
            XCTAssertEqual(transform.gridStep.rounded(), transform.gridStep)
            // Keep the grid sparse at overview scales and the scale bar within a phone screen.
            XCTAssertGreaterThanOrEqual(transform.gridStep * scale, 72)
            XCTAssertLessThanOrEqual(transform.gridStep * scale, 180)
            if scale >= 72 { XCTAssertEqual(transform.gridStep, 1) }
            else { XCTAssertGreaterThan(transform.gridStep, 1) }
        }
    }
}
