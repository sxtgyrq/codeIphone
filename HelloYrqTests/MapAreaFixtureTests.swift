import Foundation
import XCTest
@testable import HelloYrq

/// Exercise the mutable UI fixture against the server's area concurrency
/// contract. These requests are entirely in-process and never reach a server.
final class MapAreaFixtureTests: XCTestCase {
    private let bounds = MapAreaBounds(left: 0, bottom: 0, right: 50, top: 50)

    private func seed(locked: Bool = false, owner: String = "demo", nodeEditable: Bool = true) -> MapSnapshot {
        let road = MapLine(code: "AAAAAAAAAA", owner: owner, isLocked: locked, version: 7,
            nodes: [MapLinePoint(lineCode: "AAAAAAAAAA", order: 0, x: 10, y: 25),
                    MapLinePoint(lineCode: "AAAAAAAAAA", order: 1, x: 30, y: 25)],
            properties: MapLineProperties(roadName: "源线路", roadDetail: "源说明", speed: 100))
        let node = MapLogicalNode(code: "CCCCCCCCCC", owner: "demo", version: 9, x: 20.5, y: 25.5, sideLength: 6,
            properties: MapNodeProperties(value: "命题", info: "源节点", logicLanguage: "P"),
            positions: [MapNodePosition(logicalNodeCode: "CCCCCCCCCC", roadCode: "AAAAAAAAAA", roadOrder: 0,
                roadPercent: 0.525, x: 20.5, y: 25, roadVersion: 7)], canEdit: nodeEditable)
        return MapSnapshot(lines: [road], logicalNodes: [node])
    }

    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func request<T: Decodable>(_ fixture: MapEditingFixture, _ path: String,
                                      _ fields: [String: Any] = [:], as type: T.Type = T.self) throws -> T {
        var body = fields
        body[["GetLogicalNodes", "UndoMap"].contains(path) ? "userName" : "owner"] = "demo"
        body["loginCode"] = "0123456789abcdef0123456789abcdef"
        let response = try fixture.respond(path, body: body)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: response))
    }

    private func select(_ fixture: MapEditingFixture) throws -> MapAreaSelection {
        try request(fixture, "SelectMapArea", ["bounds": json(bounds)])
    }

    private func paste(_ fixture: MapEditingFixture, _ token: MapAreaSelection) throws -> MapAreaPasteResult {
        try request(fixture, "PasteMapArea", ["selection": json(token), "deltaX": 100, "deltaY": 100])
    }

    func testSystemClipboardMetadataStrippingDoesNotInvalidateAreaToken() throws {
        let original = seed(), fixture = MapEditingFixture(snapshot: seed())
        let selected = try select(fixture)
        XCTAssertFalse(selected.logicalNodes[0].positions.isEmpty)
        guard case .area(let copied) = try MapClipboardCodec.decode(MapClipboardCodec.encode(.area(selected))) else {
            return XCTFail("Expected the same area through the real clipboard codec")
        }
        XCTAssertTrue(copied.logicalNodes[0].positions.isEmpty)
        XCTAssertNil(copied.logicalNodes[0].canEdit)
        XCTAssertEqual(copied.logicalNodes[0].version, selected.logicalNodes[0].version)
        let result = try paste(fixture, copied)
        XCTAssertEqual(result.map.lines.count, 2)
        XCTAssertEqual(result.map.logicalNodes.count, 2)
        XCTAssertEqual(result.added.logicalNodes[0].x, 120.5)
        XCTAssertEqual(result.added.logicalNodes[0].y, 125.5)
        XCTAssertEqual(result.map.logicalNodes.first { $0.code == "CCCCCCCCCC" }?.properties,
                       original.logicalNodes[0].properties)
        let undo: MapUndoResult = try request(fixture, "UndoMap", ["requestId": "fixture-copy-undo"])
        XCTAssertEqual(undo.map, original)
    }

    func testAreaCopyUsesAuthoritativeGeometryAndPropertiesRatherThanPostedValues() throws {
        let fixture = MapEditingFixture(snapshot: seed()), selected = try select(fixture)
        let originalLine = selected.lines[0], originalNode = selected.logicalNodes[0]
        let changedLine = MapLine(code: originalLine.code, owner: "untrusted", isLocked: false, version: originalLine.version,
            nodes: originalLine.nodes.map { MapLinePoint(lineCode: $0.lineCode, order: $0.order, x: $0.x + 1, y: $0.y) },
            properties: MapLineProperties(roadName: "不是服务端的值", speed: 499))
        let changedNode = MapLogicalNode(code: originalNode.code, owner: "untrusted", version: originalNode.version,
            x: 22.5, y: 25.5, sideLength: 6, properties: MapNodeProperties(value: "外来数据", info: "外来说明", logicLanguage: "OTHER"))
        let token = MapAreaSelection(bounds: bounds, lines: [changedLine], logicalNodes: [changedNode], crosses: [])
        let result = try paste(fixture, token)
        XCTAssertEqual(result.added.lines[0].owner, "demo")
        XCTAssertEqual(result.added.lines[0].nodes[0].x, 110)
        XCTAssertEqual(result.added.lines[0].properties, originalLine.properties)
        XCTAssertEqual(result.added.logicalNodes[0].x, 120.5)
        XCTAssertEqual(result.added.logicalNodes[0].properties.info, "源节点")
        XCTAssertNotEqual(result.added.logicalNodes[0].properties.logicLanguage, "OTHER")
    }

    func testChangedSourceVersionIsRejectedWithoutAddingUndoOrObjects() throws {
        let fixture = MapEditingFixture(snapshot: seed()), selected = try select(fixture)
        var properties = selected.logicalNodes[0].properties
        properties.info = "远端已修改"
        let updated: MapLogicalNode = try request(fixture, "UpdateLogicalNodeWithOperandKind", [
            "code": "CCCCCCCCCC", "version": 9, "value": properties.value, "info": properties.info,
            "logicLanguage": properties.logicLanguage, "operandKind": properties.operandKind])
        XCTAssertGreaterThan(updated.version, 9)
        XCTAssertThrowsError(try paste(fixture, selected)) { error in
            XCTAssertEqual((error as? MapFixtureError)?.code, "SelectionChanged")
        }
        let nodes: [MapLogicalNode] = try request(fixture, "GetLogicalNodes")
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].properties.info, "远端已修改")
        let undo: MapUndoResult = try request(fixture, "UndoMap", ["requestId": "fixture-edit-undo"])
        XCTAssertEqual(undo.map, seed())
    }

    func testNewObjectsInsideOldBoundsDoNotJoinCopyButInvalidateMoveAndDelete() throws {
        let fixture = MapEditingFixture(snapshot: seed()), selected = try select(fixture)
        let added: MapLogicalNode = try request(fixture, "AddLogicalNodeWithOperandKind", [
            "x": 40.5, "y": 40.5, "sideLength": 6,
            "properties": json(MapNodeProperties(value: "新节点", logicLanguage: "Q"))])
        for path in ["MoveMapArea", "DeleteMapArea"] {
            XCTAssertThrowsError(try request(fixture, path, ["selection": json(selected), "deltaX": 100, "deltaY": 100],
                                            as: MapSnapshot.self)) { error in
                XCTAssertEqual((error as? MapFixtureError)?.code, "SelectionChanged")
            }
        }
        let result = try paste(fixture, selected)
        XCTAssertEqual(result.added.logicalNodes.count, 1)
        XCTAssertNil(result.logicalNodeCodes[added.code])
        XCTAssertEqual(result.map.logicalNodes.count, 3)
        XCTAssertEqual(result.map.logicalNodes.first { $0.code == added.code }?.x, 40.5)
    }

    func testAreaTokenCannotBypassCurrentOwnershipLockOrDuplicateIdentity() throws {
        for (snapshot, code) in [(seed(locked: true), "LineIsLocked"), (seed(owner: "other"), "NotOwner"),
                                 (seed(nodeEditable: false), "NotOwner")] {
            let fixture = MapEditingFixture(snapshot: snapshot)
            let token = MapAreaSelection(bounds: bounds, lines: snapshot.lines, logicalNodes: snapshot.logicalNodes, crosses: [])
            XCTAssertThrowsError(try paste(fixture, token)) { error in
                XCTAssertEqual((error as? MapFixtureError)?.code, code)
            }
        }
        let fixture = MapEditingFixture(snapshot: seed()), selected = try select(fixture)
        let duplicate = MapAreaSelection(bounds: bounds, lines: selected.lines,
            logicalNodes: selected.logicalNodes + selected.logicalNodes, crosses: [])
        XCTAssertThrowsError(try paste(fixture, duplicate)) { error in
            XCTAssertEqual((error as? MapFixtureError)?.code, "SelectionChanged")
        }
    }
}
