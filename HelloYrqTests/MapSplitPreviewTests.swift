import XCTest
@testable import HelloYrq

final class MapSplitPreviewTests: XCTestCase {
    private func line(count: Int = 6) -> MapLine {
        let code = "AAAAAAAAAA"
        return MapLine(code: code, owner: "demo", isLocked: false, version: 42,
                       nodes: (0..<count).map { MapLinePoint(lineCode: code, order: $0, x: 100 + $0 * 10, y: 200) },
                       properties: MapLineProperties(roadName: "示例", speed: 80, passInOpposeDirection: 1))
    }

    func testPreviewRemovesJoiningSegmentAndPreservesEveryOriginalPoint() throws {
        let original = line()
        let snapshot = try XCTUnwrap(MapSplitEditor.previewSnapshot(line: original, cutBeforeOrder: 3))
        XCTAssertEqual(snapshot.lines.count, 2)
        let first = snapshot.lines[0], second = snapshot.lines[1]
        XCTAssertEqual(first.nodes.map(\.x), [100, 110, 120])
        XCTAssertEqual(second.nodes.map(\.x), [130, 140, 150])
        let segments = snapshot.lines.flatMap { line in
            zip(line.nodes, line.nodes.dropFirst()).map { pair in "\(pair.0.x)-\(pair.1.x)" }
        }
        XCTAssertEqual(segments, ["100-110", "110-120", "130-140", "140-150"])
        XCTAssertEqual(snapshot.lines.flatMap(\.nodes).map(\.x), original.nodes.map(\.x))
        XCTAssertNotEqual(first.code, second.code)
        for part in snapshot.lines {
            XCTAssertEqual(part.nodes.map(\.order), Array(0..<part.nodes.count))
            XCTAssertTrue(part.isValidGeometry)
            XCTAssertEqual(part.owner, original.owner)
            XCTAssertEqual(part.properties, original.properties)
            XCTAssertEqual(part.version, original.version)
        }
        XCTAssertEqual(original.nodes.count, 6)
        XCTAssertEqual(original.version, 42)
    }

    func testOnlyCutsLeavingAtLeastTwoPointsPerLineArePreviewed() throws {
        let original = line()
        XCTAssertEqual(try XCTUnwrap(MapSplitEditor.previewSnapshot(line: original, cutBeforeOrder: 2)).lines.map { $0.nodes.count }, [2, 4])
        XCTAssertEqual(try XCTUnwrap(MapSplitEditor.previewSnapshot(line: original, cutBeforeOrder: 4)).lines.map { $0.nodes.count }, [4, 2])
        for cut in [-1, 0, 1, 5, 6, 7] {
            XCTAssertNil(MapSplitEditor.previewSnapshot(line: original, cutBeforeOrder: cut))
        }
        XCTAssertNil(MapSplitEditor.previewSnapshot(line: line(count: 3), cutBeforeOrder: 2))
        XCTAssertEqual(try XCTUnwrap(MapSplitEditor.previewSnapshot(line: line(count: 4), cutBeforeOrder: 2)).lines.map { $0.nodes.count }, [2, 2])
    }
}
