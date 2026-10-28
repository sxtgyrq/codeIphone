import Foundation
import XCTest
@testable import HelloYrq

final class MapClipboardCodecTests: XCTestCase {
    private let road = #"{"Format":"argumentmap.road/1","Source":{"Code":"AAAAAAAAAA","Version":9007199254740993,"Nodes":[{"LineCode":"AAAAAAAAAA","Order":0,"X":50,"Y":100},{"LineCode":"AAAAAAAAAA","Order":1,"X":150,"Y":100}],"Properties":{"RoadName":"原线","RoadDetail":"说明","Speed":80,"PassInDirection":1,"PassInOpposeDirection":1},"IsLocked":true}}"#

    private let area = #"{"format":"argumentmap.area/1","selection":{"bounds":{"left":0,"bottom":0,"right":300,"top":300},"lines":[{"code":"AAAAAAAAAA","owner":"demo","isLocked":false,"version":3,"nodes":[{"lineCode":"AAAAAAAAAA","order":0,"x":50,"y":100},{"lineCode":"AAAAAAAAAA","order":1,"x":150,"y":100}],"properties":{"roadName":"横线","roadDetail":"","speed":100,"passInDirection":1,"passInOpposeDirection":0}},{"code":"BBBBBBBBBB","owner":"demo","isLocked":false,"version":4,"nodes":[{"lineCode":"BBBBBBBBBB","order":0,"x":100,"y":50},{"lineCode":"BBBBBBBBBB","order":1,"x":100,"y":150}],"properties":{"roadName":"竖线","roadDetail":"","speed":100,"passInDirection":1,"passInOpposeDirection":0}}],"logicalNodes":[{"code":"CCCCCCCCCC","owner":"demo","version":5,"x":200.5,"y":200.5,"sideLength":6,"properties":{"value":"命题","info":"","logicLanguage":"P","operandKind":"Custom"},"positions":[],"canEdit":null,"isStart":false,"left":197.5,"bottom":197.5,"right":203.5,"top":203.5}],"crosses":[{"key":{"roadCode1":"BBBBBBBBBB","roadCode2":"AAAAAAAAAA","position":{"x2":200,"y2":200,"x":100,"y":100,"isInteger":true},"isValid":true},"roadOrder1":0,"roadOrder2":0,"roadVersion1":4,"roadVersion2":3,"state":2,"version":6,"percent1":0.5,"percent2":0.5,"canTransfer":true,"stateLabel":"单向：BBBBBBBBBB → AAAAAAAAAA"}]}}"#

    func testWpfPascalCaseRoadRoundTripRetainsInt64VersionLockAndProperties() throws {
        guard case .line(let source) = try MapClipboardCodec.decode(road) else { return XCTFail("Expected road") }
        XCTAssertEqual(source.version, 9_007_199_254_740_993)
        XCTAssertTrue(source.isLocked)
        XCTAssertEqual(source.properties.roadName, "原线")
        XCTAssertEqual(source.nodes.map(\.order), [0, 1])
        let encoded = try MapClipboardCodec.encode(.line(source))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["Format", "Source"])
        let payload = try XCTUnwrap(root["Source"] as? [String: Any])
        XCTAssertNotNil(payload["Nodes"])
        XCTAssertNil(payload["nodes"])
        guard case .line(let restored) = try MapClipboardCodec.decode(encoded) else { return XCTFail("Expected road") }
        XCTAssertEqual(restored, source)
    }

    func testLegacyLn4TypedLn6AndOldNegationRemainCompatible() throws {
        let legacy = #"{"format":"argumentmap.ln4/1","value":"False","logic":"¬P","info":"第一行\n第二行"}"#
        guard case .node(let branch) = try MapClipboardCodec.decode(legacy) else { return XCTFail("Expected LN") }
        XCTAssertEqual(branch.sideLength, 4)
        XCTAssertEqual(branch.properties.info, "第一行\n第二行")
        let encoded = try MapClipboardCodec.encode(.node(branch))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "argumentmap.ln4/1")
        XCTAssertNil(root["size"])
        XCTAssertNil(root["operandKind"])

        let typed = #"{"format":"argumentmap.ln/1","size":6,"value":"类命题","logic":"PERSON","info":"","operandKind":"Class"}"#
        guard case .node(let node) = try MapClipboardCodec.decode(typed) else { return XCTFail("Expected LN") }
        XCTAssertEqual(node.properties.operandKind, "Class")
        XCTAssertThrowsError(try MapClipboardCodec.decode(typed.replacingOccurrences(of: "PERSON", with: "person")))
        let oldNot = #"{"format":"argumentmap.ln/1","size":8,"value":"¬","logic":"¬","info":""}"#
        guard case .node(let not) = try MapClipboardCodec.decode(oldNot) else { return XCTFail("Expected LN") }
        XCTAssertEqual(not.properties.logicLanguage, "¬(?)")
        guard case .node(let restored) = try MapClipboardCodec.decode(MapClipboardCodec.encode(.node(not))) else { return XCTFail("Expected LN") }
        XCTAssertEqual(restored.properties, not.properties)
    }

    func testWpfAreaDerivedFieldsAreAcceptedAndTokensAreRetained() throws {
        guard case .area(let selected) = try MapClipboardCodec.decode(area) else { return XCTFail("Expected area") }
        XCTAssertEqual(selected.lines.map(\.version), [3, 4])
        XCTAssertEqual(selected.logicalNodes[0].version, 5)
        XCTAssertEqual(selected.crosses[0].version, 6)
        XCTAssertEqual(selected.crosses[0].state, 2)
        XCTAssertNil(selected.logicalNodes[0].canEdit)
        XCTAssertTrue(selected.logicalNodes[0].positions.isEmpty)
        let encoded = try MapClipboardCodec.encode(.area(selected))
        XCTAssertTrue(encoded.contains("argumentmap.area/1"))
        guard case .area(let restored) = try MapClipboardCodec.decode(encoded) else { return XCTFail("Expected area") }
        XCTAssertEqual(restored, selected)
    }

    func testMalformedUnknownDuplicateEscapedDuplicateAndWrongTypesAreRejected() {
        let invalid = [
            "{}", "[]", road + " null", road.replacingOccurrences(of: "argumentmap.road/1", with: "argumentmap.road/2"),
            road.replacingOccurrences(of: "\"Version\":9007199254740993", with: "\"Version\":-1"),
            road.replacingOccurrences(of: "\"Version\":9007199254740993", with: "\"Version\":true"),
            road.replacingOccurrences(of: "\"IsLocked\":true", with: "\"IsLocked\":1"),
            road.replacingOccurrences(of: "\"Speed\":80", with: "\"Speed\":0"),
            road.replacingOccurrences(of: "\"Order\":1", with: "\"Order\":0"),
            road.replacingOccurrences(of: "\"Order\":1", with: "\"Order\":1,\"Order\":1"),
            road.replacingOccurrences(of: "\"Order\":1", with: "\"Order\":1,\"\\u004Frder\":1"),
            road.replacingOccurrences(of: "\"Speed\":80", with: "\"Speed\":80,\"Owner\":\"admin\""),
            road.replacingOccurrences(of: "\"X\":150", with: "\"X\":150.5"),
            road.replacingOccurrences(of: "\"X\":150", with: "\"X\":500001"),
            road.replacingOccurrences(of: "\"RoadName\":\"原线\"", with: "\"RoadName\":null"),
            #"{"format":"argumentmap.ln/2","size":8,"value":"¬","logic":"¬(?)","info":""}"#,
            #"{"format":"argumentmap.ln/1","size":18,"value":"开始","logic":"","info":""}"#,
            #"{"format":"argumentmap.ln4/1","value":"True","logic":"P\nQ","info":""}"#
        ]
        for text in invalid { XCTAssertThrowsError(try MapClipboardCodec.decode(text), text) }
    }

    func testAreaRequiresIntegerCrossesCompleteRoadMembershipAndEntireLnSquares() throws {
        for text in [
            area.replacingOccurrences(of: "argumentmap.area/1", with: "argumentmap.area/2"),
            area.replacingOccurrences(of: "\"x2\":200", with: "\"x2\":201"),
            area.replacingOccurrences(of: "\"roadCode1\":\"BBBBBBBBBB\"", with: "\"roadCode1\":\"DDDDDDDDDD\""),
            area.replacingOccurrences(of: "\"x\":200.5", with: "\"x\":299.5"),
            area.replacingOccurrences(of: "\"sideLength\":6", with: "\"sideLength\":18"),
            area.replacingOccurrences(of: "\"version\":5", with: "\"version\":-1"),
            area.replacingOccurrences(of: "\"state\":2", with: "\"state\":4"),
            area.replacingOccurrences(of: "\"positions\":[]", with: "\"positions\":[{}]"),
            area.replacingOccurrences(of: "\"percent1\":0.5", with: "\"percent1\":2")
        ] { XCTAssertThrowsError(try MapClipboardCodec.decode(text)) }
    }

    func testBoundsOnInputSizeNestingAndNodeCounts() throws {
        XCTAssertThrowsError(try MapClipboardCodec.decode(String(repeating: " ", count: MapClipboardCodec.maximumRoadLength + 1)))
        XCTAssertThrowsError(try MapClipboardCodec.decode(area + String(repeating: " ", count: MapClipboardCodec.maximumAreaLength)))
        let ln = #"{"format":"argumentmap.ln4/1","value":"True","logic":"P","info":""}"#
        XCTAssertThrowsError(try MapClipboardCodec.decode(ln + String(repeating: " ", count: 8192)))
        XCTAssertThrowsError(try MapClipboardCodec.decode(String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)))
        let line = MapLine(code: "AAAAAAAAAA", owner: "demo", isLocked: false, version: 0,
            nodes: (0...100_000).map { MapLinePoint(lineCode: "AAAAAAAAAA", order: $0, x: $0, y: 100) })
        XCTAssertThrowsError(try MapClipboardCodec.encode(.line(MapLineCopyData(line: line))))
    }
}
