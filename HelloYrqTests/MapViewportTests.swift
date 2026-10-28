import CoreGraphics
import XCTest
@testable import HelloYrq

@MainActor
final class MapViewportTests: XCTestCase {
    private let phone = CGSize(width: 375, height: 476)

    private var shortLines: MapSnapshot {
        let line = MapLine(code: "AAAAAAAAAA", owner: "demo", isLocked: false, version: 1,
                           nodes: [MapLinePoint(lineCode: "AAAAAAAAAA", order: 0, x: 100, y: 100),
                                   MapLinePoint(lineCode: "AAAAAAAAAA", order: 1, x: 102, y: 102)])
        return MapSnapshot(lines: [line])
    }

    func testEmptyLoginCanvasWaitsForSnapshotThenCentersShortLines() throws {
        let interaction = MapInteraction()
        XCTAssertFalse(interaction.initializeViewport(MapViewport.fitted(snapshot: .empty, size: phone)))
        XCTAssertFalse(interaction.hasFittedViewport)
        let firstFrame = try XCTUnwrap(MapViewport.fitted(snapshot: shortLines, size: phone))
        XCTAssertEqual(firstFrame.center, CGPoint(x: 101, y: 101))
        XCTAssertGreaterThan(firstFrame.scale, 1)
        XCTAssertTrue(interaction.initializeViewport(firstFrame))
        XCTAssertEqual(interaction.cursor, firstFrame.center)
        XCTAssertEqual(interaction.currentScale, firstFrame.scale)
    }

    func testSnapshotArrivingBeforeLayoutDoesNotConsumeInitialFit() throws {
        let interaction = MapInteraction()
        XCTAssertFalse(interaction.initializeViewport(MapViewport.fitted(snapshot: shortLines, size: .zero)))
        XCTAssertFalse(interaction.hasFittedViewport)
        let viewport = try XCTUnwrap(MapViewport.fitted(snapshot: shortLines, size: phone))
        XCTAssertTrue(interaction.initializeViewport(viewport))
        XCTAssertEqual(interaction.cursor, CGPoint(x: 101, y: 101))
    }

    func testRefreshResizeAndLateInitializationPreserveManualViewport() throws {
        let interaction = MapInteraction()
        let first = try XCTUnwrap(MapViewport.fitted(snapshot: shortLines, size: phone))
        XCTAssertTrue(interaction.initializeViewport(first))
        interaction.setViewport(MapViewport(center: CGPoint(x: 108, y: 104), scale: 128))
        let refreshed = try XCTUnwrap(MapViewport.fitted(snapshot: shortLines, size: CGSize(width: 700, height: 300)))
        XCTAssertFalse(interaction.initializeViewport(refreshed))
        XCTAssertFalse(interaction.initializeViewport(first))
        XCTAssertEqual(interaction.cursor, CGPoint(x: 108, y: 104))
        XCTAssertEqual(interaction.currentScale, 128)
    }

    func testExplicitFitRestoresContentAfterPanAndZoom() throws {
        let interaction = MapInteraction()
        interaction.setViewport(MapViewport(center: CGPoint(x: 250_000, y: 250_000), scale: 128))
        let fitted = try XCTUnwrap(MapViewport.fitted(snapshot: shortLines, size: phone))
        interaction.setViewport(fitted)
        XCTAssertEqual(interaction.cursor, CGPoint(x: 101, y: 101))
        XCTAssertEqual(interaction.currentScale, fitted.scale)
        XCTAssertTrue(interaction.hasFittedViewport)
    }
}
