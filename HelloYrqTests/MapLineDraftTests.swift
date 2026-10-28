import CoreGraphics
import XCTest
@testable import HelloYrq

final class MapLineDraftTests: XCTestCase {
    private func line(_ points: [(Int, Int)] = []) -> MapLine {
        let code = "AAAAAAAAAA"
        return MapLine(code: code, owner: "demo", isLocked: false, version: 42,
                       nodes: points.enumerated().map { MapLinePoint(lineCode: code, order: $0.offset, x: $0.element.0, y: $0.element.1) })
    }

    func testEightDirectionSnapUsesNearestRayAndKeepsBoundaryDiagonals() {
        XCTAssertEqual(MapLineDraft.snap(target: CGPoint(x: 10.5, y: 20.5)), CGPoint(x: 11, y: 21))
        XCTAssertEqual(MapLineDraft.snap(target: CGPoint(x: 140, y: 103), from: CGPoint(x: 100, y: 100)), CGPoint(x: 140, y: 100))
        XCTAssertEqual(MapLineDraft.snap(target: CGPoint(x: 120, y: 123), from: CGPoint(x: 100, y: 100)), CGPoint(x: 122, y: 122))
        let atEdge = MapLineDraft.snap(target: CGPoint(x: 500_020, y: 500_040), from: CGPoint(x: 499_990, y: 499_990))
        XCTAssertEqual(atEdge, CGPoint(x: 500_000, y: 500_000))
        let atBottom = MapLineDraft.snap(target: CGPoint(x: -20, y: -20), from: CGPoint(x: 10, y: 10))
        XCTAssertEqual(atBottom, .zero)
    }

    func testPrependAppendInsertDeleteAndReverseRenumberWithoutChangingOriginalVersion() throws {
        let original = line([(100,100),(110,100)])
        var draft = MapLineDraft(line: original)
        draft.addFromStart = true
        try draft.addPoint(CGPoint(x: 90, y: 102))
        draft.addFromStart = false
        try draft.addPoint(CGPoint(x: 120, y: 99))
        try draft.insertPoint(CGPoint(x: 105, y: 100), after: 1)
        XCTAssertEqual(draft.points.map(\.x), [90,100,105,110,120])
        try draft.removePoint(at: 2)
        draft.reverse()
        XCTAssertEqual(draft.points.map(\.x), [120,110,100,90])
        XCTAssertEqual(draft.points.map(\.order), [0,1,2,3])
        XCTAssertTrue(draft.points.allSatisfy { $0.lineCode == original.code })
        XCTAssertEqual(draft.original, original)
        XCTAssertEqual(draft.version, 42)
        XCTAssertNil(draft.validationMessage)
    }

    func testInvalidEditsDoNotPartiallyChangeDraftAndServerProposalRetainsOtherNodes() throws {
        var draft = MapLineDraft(line: line([(100,100),(110,100),(110,110)]))
        let before = draft
        XCTAssertThrowsError(try draft.movePoint(at: 1, to: CGPoint(x: 107, y: 103)))
        XCTAssertThrowsError(try draft.insertPoint(CGPoint(x: 105, y: 103), after: 0))
        XCTAssertThrowsError(try draft.addPoint(CGPoint(x: 600_000, y: 100)))
        XCTAssertThrowsError(try draft.replacePoint(at: 0, x: 110, y: 110))
        XCTAssertEqual(draft, before)
        try draft.replacePoint(at: 1, x: 100, y: 110)
        XCTAssertEqual(draft.points[0], before.points[0])
        XCTAssertEqual(draft.points[2], before.points[2])
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.version, 42)
    }

    func testDeletionRejectsBrokenDirectionAndDraftCanBeEmptyBeforeSaving() throws {
        var draft = MapLineDraft(line: line([(100,100),(110,100),(110,120)]))
        let before = draft
        XCTAssertThrowsError(try draft.removePoint(at: 1))
        XCTAssertEqual(draft, before)
        try draft.removePoint(at: 2)
        try draft.removePoint(at: 1)
        XCTAssertNotNil(draft.validationMessage)
        try draft.removePoint(at: 0)
        XCTAssertTrue(draft.points.isEmpty)
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertEqual(draft.original.nodes.count, 3)
    }

    func testAutomaticInsertionRoundsAndChoosesSmallestIncreaseAcrossAllSlots() throws {
        let original = line([(100,100),(120,100),(120,110),(100,110)])
        var draft = MapLineDraft(line: original)
        draft.addFromStart = true
        // The first segment accepts a longer detour; the last accepts no detour.
        try draft.insertPointAutomatically(CGPoint(x: 109.5, y: 109.5))
        XCTAssertEqual(draft.points.map(\.x), [100,120,120,110,100])
        XCTAssertEqual(draft.points.map(\.y), [100,100,110,110,110])
        XCTAssertEqual(draft.points.map(\.order), [0,1,2,3,4])
        XCTAssertTrue(draft.points.allSatisfy { $0.lineCode == original.code })
        XCTAssertEqual(draft.original, original)
        XCTAssertEqual(draft.version, 42)
        XCTAssertTrue(draft.addFromStart)
        XCTAssertNil(draft.validationMessage)
    }

    func testAutomaticInsertionCanChooseEitherEndpointRegardlessOfAdditionMode() throws {
        let original = line([(100,100),(110,100)])
        var before = MapLineDraft(line: original)
        try before.insertPointAutomatically(CGPoint(x: 90, y: 100))
        XCTAssertEqual(before.points.map(\.x), [90,100,110])
        XCTAssertEqual(before.points.map(\.order), [0,1,2])
        XCTAssertFalse(before.addFromStart)
        var after = MapLineDraft(line: original)
        after.addFromStart = true
        try after.insertPointAutomatically(CGPoint(x: 120, y: 100))
        XCTAssertEqual(after.points.map(\.x), [100,110,120])
        XCTAssertEqual(after.points.map(\.order), [0,1,2])
        XCTAssertTrue(after.addFromStart)
        XCTAssertEqual(before.original, original)
        XCTAssertEqual(after.original, original)
    }

    func testAutomaticInsertionKeepsEarliestSlotWhenLengthIncreasesTie() throws {
        var draft = MapLineDraft(line: line([(100,100),(100,120),(120,120),(120,100)]))
        // All three interior detours have the same length; slot 1 must win.
        try draft.insertPointAutomatically(CGPoint(x: 110, y: 110))
        XCTAssertEqual(draft.points.map(\.x), [100,110,100,120,120])
        XCTAssertEqual(draft.points.map(\.y), [100,110,120,120,100])
        XCTAssertNil(draft.validationMessage)
    }

    func testAutomaticInsertionRejectsInvalidTargetsWithoutChangingDraft() {
        var draft = MapLineDraft(line: line([(100,100),(110,100)]))
        let original = draft
        let rejected = [CGPoint(x: 105, y: 103), // No legal eight-direction slot.
                        CGPoint(x: 100.4, y: 100.4), // Rounds onto an existing point.
                        CGPoint(x: -0.1, y: 100), CGPoint(x: 500_000.1, y: 100),
                        CGPoint(x: CGFloat.nan, y: 100), CGPoint(x: 100, y: CGFloat.infinity)]
        for target in rejected {
            XCTAssertThrowsError(try draft.insertPointAutomatically(target))
            XCTAssertEqual(draft, original)
        }
        let shortInputs: [[(Int, Int)]] = [[], [(100,100)]]
        for nodes in shortInputs {
            var shortDraft = MapLineDraft(line: line(nodes))
            let original = shortDraft
            XCTAssertThrowsError(try shortDraft.insertPointAutomatically(CGPoint(x: 110, y: 100)))
            XCTAssertEqual(shortDraft, original)
        }
    }

    func testAutomaticInsertionLeavesLongSegmentsForServerSubdivision() throws {
        var draft = MapLineDraft(line: line([(100,100),(100,200)]))
        try draft.insertPointAutomatically(CGPoint(x: 100, y: 1_200))
        XCTAssertEqual(draft.points.map(\.y), [100,200,1_200])
        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.version, 42)
    }
}
