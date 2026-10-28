import Foundation
import XCTest
@testable import HelloYrq

/// Writes are captured by URLProtocol. No test logs in to or modifies a real map.
final class MapEditingAPITests: XCTestCase {
    private var transport: URLSession!
    private let account = MapSession(userName: "编辑者", loginCode: "0123456789abcdef0123456789abcdef")
    private var api: MapAPI { MapAPI(serverURL: URL(string: "https://192.168.1.20:61011/")!, session: transport) }

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapEditStubProtocol.self]
        transport = URLSession(configuration: configuration)
    }

    override func tearDown() {
        transport.invalidateAndCancel()
        transport = nil
        MapEditStubProtocol.install(nil)
        super.tearDown()
    }

    private var line: MapLine {
        MapLine(code: "ZZZZZZZZZZ", owner: "另一位负责人", isLocked: false, version: 9_007_199_254_740_993,
                nodes: [MapLinePoint(lineCode: "ZZZZZZZZZZ", order: 0, x: 100, y: 110),
                        MapLinePoint(lineCode: "ZZZZZZZZZZ", order: 1, x: 120, y: 110)])
    }
    private var secondLine: MapLine {
        MapLine(code: "AAAAAAAAAA", owner: "编辑者", isLocked: false, version: 7,
                nodes: [MapLinePoint(lineCode: "AAAAAAAAAA", order: 0, x: 120, y: 110),
                        MapLinePoint(lineCode: "AAAAAAAAAA", order: 1, x: 140, y: 110)])
    }
    private var node: MapLogicalNode {
        MapLogicalNode(code: "BBBBBBBBBB", owner: "另一位负责人", version: 11, x: 110.5, y: 110.5,
                       sideLength: 8, properties: MapNodeProperties(value: "¬", info: "说明", logicLanguage: "¬(?)"), canEdit: true)
    }
    private var target: MapLogicalNode {
        MapLogicalNode(code: "CCCCCCCCCC", owner: "编辑者", version: 12, x: 150.5, y: 110.5,
                       sideLength: 6, properties: MapNodeProperties(value: "命题", logicLanguage: "SOMETHING", operandKind: "Class"), canEdit: true)
    }
    private var cross: MapCross {
        MapCross(key: MapCrossKey(roadCode1: line.code, roadCode2: secondLine.code,
                                 position: MapCrossPosition(x2: 240, y2: 220)),
                 roadOrder1: 0, roadOrder2: 0, roadVersion1: line.version, roadVersion2: secondLine.version,
                 state: 2, version: 19, percent1: 1, percent2: 0)
    }
    private var map: MapSnapshot { MapSnapshot(lines: [line, secondLine], logicalNodes: [node, target], crosses: [cross]) }
    private var bounds: MapAreaBounds { MapAreaBounds(left: 90, bottom: 90, right: 170, top: 130) }
    private var selection: MapAreaSelection {
        MapAreaSelection(bounds: bounds, lines: map.lines, logicalNodes: map.logicalNodes, crosses: map.crosses)
    }
    private var mergePlan: MapMergePlan {
        MapMergePlan(firstX: 120, firstY: 110, secondX: 120, secondY: 110,
                     directionX: 1, directionY: 0, firstCorner: 1, secondCorner: 0, adjustedGridSteps: 0)
    }
    private var connection: MapLogicalNodeConnectionPlan {
        MapLogicalNodeConnectionPlan(source: MapLogicalNodeConnectionAnchor(node: node),
            target: MapLogicalNodeConnectionAnchor(node: target), lineCode: line.code, nodes: line.nodes,
            kind: .goTo, join: MapLogicalNodeConnectionJoin(roadCode: secondLine.code, position: cross.key.position),
            continuation: [MapLogicalNodeContinuationPoint(roadCode: secondLine.code, x: 130, y: 110)])
    }

    private func respond<Value: Encodable>(_ value: Value, path: String,
                                          inspect: @escaping ([String: Any], URLRequest) throws -> Void = { _, _ in }) {
        let token = account.loginCode
        let owner = account.userName
        MapEditStubProtocol.install { request in
            XCTAssertEqual(request.url?.lastPathComponent, path)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
            let body = try MapEditStubProtocol.body(request)
            XCTAssertEqual(body["loginCode"] as? String, token)
            XCTAssertEqual((body["owner"] ?? body["userName"]) as? String, owner)
            XCTAssertNil(body["password"])
            try inspect(body, request)
            return (200, try JSONEncoder().encode(MapEditEnvelope(success: true, code: "Ok", message: "已完成", data: value)))
        }
    }

    func testLineCreationAccessAndSaveUseAuthenticatedOwnerAndExactVersion() async throws {
        let value = line
        respond(value, path: "AddLine") { body, _ in XCTAssertEqual(Set(body.keys), ["owner", "loginCode"]) }
        _ = try await api.createLine(session: account)
        respond(value, path: "StartToDraw") { body, _ in XCTAssertEqual(body["lineCode"] as? String, value.code) }
        _ = try await api.startDrawing(lineCode: value.code, session: account)
        respond(value, path: "GetLineDetail")
        _ = try await api.lineDetail(lineCode: value.code, session: account)
        respond(value, path: "CheckShapeIsOKThenSave") { body, _ in
            XCTAssertEqual((body["version"] as? NSNumber)?.int64Value, value.version)
            let nodes = try XCTUnwrap(body["nodes"] as? [[String: Any]])
            XCTAssertEqual(nodes.count, 2)
            XCTAssertEqual(nodes[1]["order"] as? Int, 1)
            XCTAssertEqual(nodes[1]["lineCode"] as? String, value.code)
            XCTAssertEqual(nodes[1]["x"] as? Int, 120)
        }
        _ = try await api.saveLine(lineCode: value.code, version: value.version, nodes: value.nodes, session: account)
    }

    func testLinePropertiesDirectionLockAndDeleteKeepVersionPreconditions() async throws {
        let value = line
        var properties = value.properties; properties.roadName = "新名称"; properties.speed = 75; properties.passInOpposeDirection = 1
        respond(value, path: "SetLineProperty") { body, _ in
            XCTAssertEqual((body["version"] as? NSNumber)?.int64Value, value.version)
            let sent = try XCTUnwrap(body["properties"] as? [String: Any])
            XCTAssertEqual(sent["roadName"] as? String, "新名称")
            XCTAssertEqual(sent["speed"] as? Int, 75)
            XCTAssertEqual(sent["passInOpposeDirection"] as? Int, 1)
        }
        _ = try await api.saveLineProperties(lineCode: value.code, version: value.version, properties: properties, session: account)
        for path in ["LockLine", "ReverseLine"] {
            respond(value, path: path) { body, _ in XCTAssertEqual((body["version"] as? NSNumber)?.int64Value, value.version) }
            if path == "LockLine" { _ = try await api.toggleLineLock(lineCode: value.code, version: value.version, session: account) }
            else { _ = try await api.reverseLine(lineCode: value.code, version: value.version, session: account) }
        }
        respond(true, path: "RemoveLine") { body, _ in XCTAssertEqual((body["version"] as? NSNumber)?.int64Value, value.version) }
        _ = try await api.deleteLine(lineCode: value.code, version: value.version, session: account)
    }

    func testNodePositionSplitAndMergeUseServerProposalAndPreviewVersions() async throws {
        respond(MapNodePositionProposal(nodeOrder: 1, x: 121, y: 110), path: "FindNodePosition") { body, _ in
            XCTAssertEqual(body["nodeOrder"] as? Int, 1)
            XCTAssertEqual(body["targetX"] as? Double, 121.3)
            XCTAssertEqual((body["nodes"] as? [[String: Any]])?.count, 2)
        }
        let proposal = try await api.findNodePosition(lineCode: line.code, version: line.version, nodes: line.nodes,
                                                      nodeOrder: 1, targetX: 121.3, targetY: 110.2, session: account)
        XCTAssertEqual(proposal.x, 121)
        let topology = MapLineTopologyResult(lines: [line, secondLine], removedCodes: [], adjustedGridSteps: 0)
        respond(topology, path: "SplitLine") { body, _ in XCTAssertEqual(body["cutBeforeOrder"] as? Int, 1) }
        _ = try await api.splitLine(lineCode: line.code, version: line.version, cutBeforeOrder: 1, session: account)
        let preview = MapMergePreview(first: line, second: secondLine, plans: [mergePlan])
        respond(preview, path: "GetMergePlans") { body, _ in
            XCTAssertEqual((body["firstVersion"] as? NSNumber)?.int64Value, preview.first.version)
            XCTAssertEqual((body["secondVersion"] as? NSNumber)?.int64Value, preview.second.version)
        }
        let actual = try await api.mergePlans(first: line, second: secondLine, session: account)
        XCTAssertEqual(actual, preview)
        respond(topology, path: "MergeLines") { body, _ in
            XCTAssertEqual((body["firstVersion"] as? NSNumber)?.int64Value, preview.first.version)
            XCTAssertEqual(body["firstX"] as? Int, 120)
            XCTAssertEqual(body["secondY"] as? Int, 110)
            XCTAssertNil(body["plan"])
        }
        _ = try await api.mergeLines(preview: actual, plan: mergePlan, session: account)
    }

    func testCrossEditingPreservesCanonicalIdentityAndBothSingleDirections() async throws {
        let value = cross
        for state in [-1, 0, 1, 2, 3] {
            respond(value, path: "EditCross") { body, _ in
                XCTAssertEqual(body["state"] as? Int, state)
                XCTAssertEqual(body["version"] as? Int, 19)
                let key = try XCTUnwrap(body["cross"] as? [String: Any])
                XCTAssertEqual(key["roadCode1"] as? String, value.key.roadCode1)
                XCTAssertEqual(key["roadCode2"] as? String, value.key.roadCode2)
                let position = try XCTUnwrap(key["position"] as? [String: Any])
                XCTAssertEqual(position["x2"] as? Int, 240)
                XCTAssertEqual(position["y2"] as? Int, 220)
                XCTAssertNil(position["x"])
            }
            _ = try await api.editCross(cross: value, state: state, session: account)
        }
    }

    func testIncrementalCalculationsKeepContinuationCursorAndDoNotLoopInsideAPI() async throws {
        respond(MapCrossCalculationProgress(canContinue: true, remainingSegments: 8, crossCount: 12), path: "CalculateCross") { body, _ in
            XCTAssertEqual(Set(body.keys), ["userName", "loginCode"])
        }
        let progress = try await api.calculateCross(session: account)
        XCTAssertTrue(progress.canContinue)
        XCTAssertEqual(progress.remainingSegments, 8)
        respond(MapLogicalNodeCalculationProgress(canContinue: true, remainingNodes: 4, nodeCount: 6, nextCode: "CCCCCCCCCC"),
                path: "CalculateLogicalNode") { body, _ in
            XCTAssertEqual(body["incremental"] as? Bool, true)
            XCTAssertEqual(body["afterCode"] as? String, "BBBBBBBBBB")
        }
        let nodes = try await api.calculateLogicalNodes(afterCode: "BBBBBBBBBB", session: account)
        XCTAssertEqual(nodes.nextCode, "CCCCCCCCCC")
    }

    func testLogicalNodeCreationPreservesHalfCoordinatesTypedOperandAndInstanceParent() async throws {
        let properties = target.properties
        respond(target, path: "AddLogicalNodeWithOperandKind") { body, _ in
            XCTAssertEqual(body["x"] as? Double, 150.5)
            XCTAssertEqual(body["y"] as? Double, 110.5)
            XCTAssertEqual(body["sideLength"] as? Int, 6)
            XCTAssertEqual((body["properties"] as? [String: Any])?["operandKind"] as? String, "Class")
        }
        _ = try await api.createLogicalNode(x: 150.5, y: 110.5, sideLength: 6, properties: properties, session: account)
        respond(node, path: "AddLogicalNode") { body, _ in
            XCTAssertEqual(body["sideLength"] as? Int, 10)
            XCTAssertEqual(body["instanceParentCode"] as? String, "CCCCCCCCCC")
        }
        _ = try await api.createLogicalNode(x: 180.5, y: 110.5, sideLength: 10,
            properties: MapNodeProperties(value: "成员", logicLanguage: "member∈CLASS"), instanceParentCode: target.code, session: account)
    }

    func testLogicalNodeUpdateMoveDeleteUseOriginalVersionAndExactLogicText() async throws {
        let value = node
        respond(value, path: "UpdateLogicalNodeWithOperandKind") { body, _ in
            XCTAssertEqual(body["code"] as? String, value.code)
            XCTAssertEqual(body["version"] as? Int, 11)
            XCTAssertEqual(body["logicLanguage"] as? String, "¬(?)")
            XCTAssertEqual(body["operandKind"] as? String, "Custom")
        }
        _ = try await api.updateLogicalNode(node: value, properties: value.properties, session: account)
        respond(value, path: "MoveLogicalNode") { body, _ in
            XCTAssertEqual(body["x"] as? Double, 200.5)
            XCTAssertEqual(body["version"] as? Int, 11)
        }
        _ = try await api.moveLogicalNode(node: value, x: 200.5, y: 210.5, session: account)
        respond(true, path: "RemoveLogicalNode") { body, _ in XCTAssertEqual(body["version"] as? Int, 11) }
        _ = try await api.deleteLogicalNode(node: value, session: account)
    }

    func testConnectionPreviewUsesGeometryAnchorsAndConfirmationPreservesWholePlan() async throws {
        let plan = connection
        respond(plan, path: "PreviewLogicalNodeConnection") { body, request in
            XCTAssertEqual(body["kind"] as? Int, 1)
            XCTAssertEqual(request.timeoutInterval, 180)
            let source = try XCTUnwrap(body["source"] as? [String: Any])
            XCTAssertEqual(source["code"] as? String, plan.source.code)
            XCTAssertEqual(source["x"] as? Double, 110.5)
            XCTAssertNil(source["version"])
        }
        let preview = try await api.previewLogicalNodeConnection(source: node, target: target, kind: .goTo, session: account)
        XCTAssertEqual(preview, plan)
        respond(MapLogicalNodeConnectionResult(line: line, map: map, disconnectedCrosses: 1), path: "SaveLogicalNodeConnection") { body, _ in
            let sent = try XCTUnwrap(body["plan"] as? [String: Any])
            XCTAssertEqual(sent["kind"] as? Int, 1)
            XCTAssertEqual((sent["continuation"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual((sent["join"] as? [String: Any])?["roadCode"] as? String, "AAAAAAAAAA")
            XCTAssertEqual((sent["nodes"] as? [[String: Any]])?.count, 2)
        }
        _ = try await api.saveLogicalNodeConnection(plan: preview, session: account)
    }

    func testAreaOperationsSendOriginalSnapshotsForConcurrencyAndRetainCrossSettings() async throws {
        let selected = selection
        respond(selected, path: "SelectMapArea") { body, _ in
            XCTAssertEqual((body["bounds"] as? [String: Any])?["right"] as? Double, 170)
        }
        let actual = try await api.selectMapArea(bounds: bounds, session: account)
        XCTAssertEqual(actual, selected)
        let inspect: ([String: Any], URLRequest) throws -> Void = { body, _ in
            let token = try XCTUnwrap(body["selection"] as? [String: Any])
            let lines = try XCTUnwrap(token["lines"] as? [[String: Any]])
            XCTAssertEqual((lines[0]["version"] as? NSNumber)?.int64Value, selected.lines[0].version)
            let crosses = try XCTUnwrap(token["crosses"] as? [[String: Any]])
            XCTAssertEqual(crosses[0]["state"] as? Int, 2)
            XCTAssertEqual(crosses[0]["version"] as? Int, 19)
        }
        respond(map, path: "MoveMapArea") { body, request in
            try inspect(body, request)
            XCTAssertEqual(body["deltaX"] as? Int, 20)
            XCTAssertEqual(body["deltaY"] as? Int, -10)
        }
        _ = try await api.moveMapArea(selection: actual, deltaX: 20, deltaY: -10, session: account)
        respond(MapAreaPasteResult(added: map, map: map, logicalNodeCodes: [:], roadCodes: [:], notes: ["引用已同步"]), path: "PasteMapArea", inspect: inspect)
        _ = try await api.pasteMapArea(selection: actual, deltaX: 100, deltaY: 100, session: account)
        respond(map, path: "DeleteMapArea", inspect: inspect)
        _ = try await api.deleteMapArea(selection: actual, session: account)
        respond(MapLinePasteResult(line: line, map: map), path: "PasteLine") { body, _ in
            let copied = try XCTUnwrap(body["source"] as? [String: Any])
            XCTAssertEqual((copied["version"] as? NSNumber)?.int64Value, selected.lines[0].version)
            XCTAssertEqual(body["x"] as? Int, 300)
            XCTAssertEqual(body["y"] as? Int, 200)
        }
        _ = try await api.pasteLine(source: MapLineCopyData(line: line), x: 300, y: 200, session: account)
    }

    func testFlowPreviewAllowsNullMapButImportRequiresCommittedMap() async throws {
        let text = "{\"format\":\"fixture\"}\n"
        let preview = MapFlowDiagramResult(added: map, map: nil, logicalNodeCodes: [:], roadCodes: [:], notes: [])
        respond(preview, path: "PreviewFlowDiagram") { body, request in
            XCTAssertEqual(body["text"] as? String, text)
            XCTAssertEqual(body["x"] as? Double, 100.5)
            XCTAssertEqual(request.timeoutInterval, 120)
        }
        let result = try await api.previewFlowDiagram(text: text, x: 100.5, y: 200.5, session: account)
        XCTAssertNil(result.map)
        respond(preview, path: "ImportFlowDiagram")
        do { _ = try await api.importFlowDiagram(text: text, x: 100.5, y: 200.5, session: account); XCTFail("Missing committed map must not appear as success") }
        catch let error as MapAPIError { XCTAssertEqual(error.code, "InvalidResponse") }
    }

    func testUndoRetryKeepsCallerRequestIdAfterUncertainResponse() async throws {
        let requestID = "0123456789abcdef0123456789abcdef"
        MapEditStubProtocol.install { request in
            let body = try MapEditStubProtocol.body(request)
            XCTAssertEqual(body["requestId"] as? String, requestID)
            throw URLError(.networkConnectionLost)
        }
        do { _ = try await api.undoMap(requestID: requestID, session: account); XCTFail("Expected uncertain response") }
        catch let error as MapAPIError { XCTAssertEqual(error.code, "ConnectionFailure") }
        respond(MapUndoResult(operation: "移动 LN", map: map), path: "UndoMap") { body, _ in
            XCTAssertEqual(body["requestId"] as? String, requestID)
            XCTAssertEqual(Set(body.keys), ["userName", "loginCode", "requestId"])
        }
        let result = try await api.undoMap(requestID: requestID, session: account)
        XCTAssertEqual(result.operation, "移动 LN")
    }

    func testPositionProposalMustMatchRequestedNodeAndMapBounds() async {
        for proposal in [MapNodePositionProposal(nodeOrder: 0, x: 121, y: 110),
                         MapNodePositionProposal(nodeOrder: 1, x: -1, y: 110),
                         MapNodePositionProposal(nodeOrder: 1, x: 121, y: 500_001)] {
            respond(proposal, path: "FindNodePosition")
            do {
                _ = try await api.findNodePosition(lineCode: line.code, version: line.version, nodes: line.nodes,
                                                   nodeOrder: 1, targetX: 121, targetY: 110, session: account)
                XCTFail("An invalid proposal must not move a different node or leave the map")
            } catch let error as MapAPIError { XCTAssertEqual(error.code, "InvalidResponse") }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testVersionConflictAndPermissionErrorsDoNotMasqueradeAsSuccess() async {
        for code in ["VersionConflict", "NotOwner", "LineLocked", "LoginExpired"] {
            MapEditStubProtocol.install { _ in
                (code == "LoginExpired" ? 401 : 200,
                 Data("{\"success\":false,\"code\":\"\(code)\",\"message\":\"请刷新后重试\",\"data\":null}".utf8))
            }
            do { _ = try await api.saveLine(lineCode: line.code, version: line.version, nodes: line.nodes, session: account); XCTFail("Expected \(code)") }
            catch let error as MapAPIError { XCTAssertEqual(error.code, code) }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInvalidWriteResultsAreReportedAsUncertainInsteadOfReplacingMap() async {
        respond(false, path: "RemoveLine")
        do { _ = try await api.deleteLine(lineCode: line.code, version: line.version, session: account); XCTFail("False deletion is not a confirmed save") }
        catch let error as MapAPIError { XCTAssertEqual(error.code, "InvalidResponse") }
        catch { XCTFail("Unexpected error: \(error)") }

        let invalidLine = MapLine(code: line.code, owner: account.userName, isLocked: false, version: 3,
                                  nodes: [MapLinePoint(lineCode: line.code, order: 0, x: 500_001, y: 110)])
        respond(MapUndoResult(operation: "移动线路", map: MapSnapshot(lines: [invalidLine])), path: "UndoMap")
        do { _ = try await api.undoMap(requestID: "0123456789abcdef0123456789abcdef", session: account); XCTFail("Invalid committed-map response must be surfaced") }
        catch let error as MapAPIError { XCTAssertEqual(error.code, "InvalidResponse") }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

private struct MapEditEnvelope<Value: Encodable>: Encodable {
    let success: Bool
    let code: String
    let message: String
    let data: Value
}

private final class MapEditStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?
    static func install(_ newHandler: ((URLRequest) throws -> (Int, Data))?) {
        lock.lock(); defer { lock.unlock() }; handler = newHandler
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let respond = Self.handler; Self.lock.unlock()
        do {
            guard let respond else { throw URLError(.resourceUnavailable) }
            let (status, data) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
