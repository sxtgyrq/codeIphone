#if DEBUG
import Foundation

// Compiled only for Debug. Activated only by the native UI test launch argument;
// normal launches always use the real Server and never display fixture data.
enum MapUITestSupport {
    @MainActor
    static func makeModel() -> MapViewModel {
        MapUITestProtocol.resetEditingState()
        let defaults = UserDefaults(suiteName: "ArgumentMap.UITests")!
        defaults.removePersistentDomain(forName: "ArgumentMap.UITests")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapUITestProtocol.self]
        let session = URLSession(configuration: configuration)
        return MapViewModel(defaults: defaults, makeAPI: { MapAPI(serverURL: $0, session: session) })
    }
}

private final class MapUITestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var lineReads = 0
    private static let editingLock = NSLock()
    private static var editing: MapEditingFixture?

    static func resetEditingState() {
        editingLock.lock(); defer { editingLock.unlock() }
        let data = try! JSONSerialization.data(withJSONObject: ["lines": lines, "logicalNodes": nodes, "crosses": crosses])
        editing = MapEditingFixture(snapshot: try! JSONDecoder().decode(MapSnapshot.self, from: data))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.lastPathComponent
        let scenario = ProcessInfo.processInfo.environment["MAP_UI_SCENARIO"] ?? "success"
        if scenario == "editing" { editingResponse(path); return }
        if scenario == "unreachable" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if path == "Login" {
            let text = scenario == "invalid-login" ? "" : "0123456789abcdef0123456789abcdef"
            reply(Data(text.utf8), status: 200, contentType: "text/plain")
            return
        }
        if path == "GetAllLineData" {
            Self.lock.lock()
            Self.lineReads += 1
            let read = Self.lineReads
            Self.lock.unlock()
            if scenario == "expired" && read > 1 {
                envelope(success: false, data: NSNull(), status: 401, code: "LoginExpired", message: "登录已失效，请重新登录。")
                return
            }
            if scenario == "refresh-failure" && read > 1 {
                envelope(success: false, data: NSNull(), status: 500, code: "DatabaseError", message: "服务暂时不可用。")
                return
            }
        }
        let empty = scenario == "empty"
        let unitDetail = scenario == "unit-detail"
        switch path {
        case "GetAllLineData": envelope(data: empty ? [] : unitDetail ? Self.unitLines : Self.lines)
        case "GetAllCrossData": envelope(data: empty || unitDetail ? [] : Self.crosses)
        case "GetLogicalNodes":
            Self.lock.lock(); let reads = Self.lineReads; Self.lock.unlock()
            var result = empty || unitDetail ? [] : Self.nodes
            if scenario == "success" && reads > 1 {
                result.append(["code": "IIIIIIIIII", "owner": "demo", "version": 1,
                               "x": 300.5, "y": 160.5, "sideLength": 12,
                               "properties": ["value": "刷新新增", "info": "", "logicLanguage": "第二次读取", "operandKind": "Custom"],
                               "positions": [], "canEdit": true])
            }
            envelope(data: result)
        case "Logout": envelope(data: true)
        default: envelope(success: false, data: NSNull(), status: 404, code: "UnexpectedEndpoint", message: "Unexpected test request")
        }
    }

    private func editingResponse(_ path: String) {
        do {
            guard request.httpMethod == "POST" else { throw MapFixtureError("InvalidRequest", "Expected POST") }
            let body: [String: Any]
            if let data = request.httpBody {
                body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&bytes, maxLength: bytes.count)
                    if read > 0 { data.append(contentsOf: bytes.prefix(read)) } else { break }
                }
                body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } else { throw MapFixtureError("InvalidRequest", "Missing JSON body") }
            if path == "Login" {
                guard Set(body.keys) == ["userName", "password", "dbPrefix"], body["userName"] as? String == "demo",
                      body["password"] as? String == "test-password", body["dbPrefix"] as? String == "ArgumentMap" else {
                    throw MapFixtureError("InvalidCredentials", "UI test login contract changed")
                }
                reply(Data("0123456789abcdef0123456789abcdef".utf8), status: 200, contentType: "text/plain")
                return
            }
            Self.editingLock.lock()
            let response: Result<Any, Error>
            do {
                guard let fixture = Self.editing else { throw MapFixtureError("InvalidFixture", "Fixture not initialized") }
                response = .success(try fixture.respond(path, body: body))
            } catch { response = .failure(error) }
            Self.editingLock.unlock()
            envelope(data: try response.get())
        } catch let failure as MapFixtureError {
            envelope(success: false, data: NSNull(), status: 200, code: failure.code, message: failure.message)
        } catch {
            envelope(success: false, data: NSNull(), status: 200, code: "InvalidFixtureRequest", message: error.localizedDescription)
        }
    }

    private func envelope(success: Bool = true, data: Any, status: Int = 200, code: String = "Ok", message: String = "已加载") {
        let value: [String: Any] = ["success": success, "code": code, "message": message, "data": data]
        reply(try! JSONSerialization.data(withJSONObject: value), status: status, contentType: "application/json")
    }

    private func reply(_ data: Data, status: Int, contentType: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func line(_ code: String, points: [[Int]], reverse: Int) -> [String: Any] {
        let vertices = points.enumerated().map { index, xy -> [String: Any] in
            ["lineCode": code, "order": index, "x": xy[0], "y": xy[1]]
        }
        return ["code": code, "owner": "demo", "isLocked": false, "version": 1, "nodes": vertices,
                "properties": ["roadName": "示例线路", "roadDetail": "UI 测试", "speed": 100, "passInDirection": 1, "passInOpposeDirection": reverse]]
    }

    private static var lines: [[String: Any]] {
        [line("BBBBBBBBBB", points: [[80,110],[275,110]], reverse: 0),
         line("AAAAAAAAAA", points: [[225,90],[225,135]], reverse: 1)]
    }

    private static var unitLines: [[String: Any]] {
        [line("BBBBBBBBBB", points: [[100,100],[101,100]], reverse: 0),
         line("AAAAAAAAAA", points: [[102,100],[102,101]], reverse: 0),
         line("CCCCCCCCCC", points: [[100,101],[101,102]], reverse: 0)]
    }

    private static var crosses: [[String: Any]] {
        [["key": ["roadCode1": "BBBBBBBBBB", "roadCode2": "AAAAAAAAAA", "position": ["x2": 450, "y2": 220]],
          "roadOrder1": 0, "roadOrder2": 0, "roadVersion1": 1, "roadVersion2": 1,
          "state": 1, "version": 1, "percent1": 0.743589743589744, "percent2": 0.444444444444444]]
    }

    private static var nodes: [[String: Any]] {
        let definitions: [(String, Int, Double, String, String)] = [
            ("CCCCCCCCCC",4,100.5,"True","示例命题"),
            ("DDDDDDDDDD",8,125.5,"¬","¬(?)"),
            ("EEEEEEEEEE",6,150.5,"命题","示例命题"),
            ("FFFFFFFFFF",10,180.5,"human(name=Alice)","human(name=Alice)∈HUMAN"),
            ("GGGGGGGGGG",12,210.5,"HUMAN","人类"),
            ("HHHHHHHHHH",18,250.5,"开始","从这里开始")]
        return definitions.map { item -> [String: Any] in
            ["code": item.0, "owner": "demo", "version": 1, "x": item.2, "y": 110.5, "sideLength": item.1,
             "properties": ["value": item.3, "info": "仅用于原生 UI 测试", "logicLanguage": item.4, "operandKind": "Custom"],
             "positions": [], "canEdit": true]
        }
    }
}

struct MapFixtureError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// An in-process server double for touch workflow tests only. It validates
/// authentication, wire fields and versions and keeps atomic undo snapshots.
/// It is not a replacement for the C# geometry/business-rule test suite.
final class MapEditingFixture {
    private var snapshot: MapSnapshot
    private var serial = 0
    private var history: [(String, MapSnapshot)] = []
    private var undoReplies: [String: MapUndoResult] = [:]
    private var pendingConnection: MapLogicalNodeConnectionPlan?

    init(snapshot: MapSnapshot) { self.snapshot = snapshot }

    func respond(_ path: String, body: [String: Any]) throws -> Any {
        let before = snapshot, count = history.count
        do { return try perform(path, body: body) }
        catch {
            snapshot = before
            if history.count > count { history.removeLast(history.count - count) }
            throw error
        }
    }

    private func perform(_ path: String, body: [String: Any]) throws -> Any {
        let userPaths: Set<String> = ["GetAllLineData", "GetAllCrossData", "GetLogicalNodes", "Logout", "CalculateCross", "CalculateLogicalNode", "UndoMap"]
        try require(body, [userPaths.contains(path) ? "userName" : "owner", "loginCode"])
        guard body[userPaths.contains(path) ? "userName" : "owner"] as? String == "demo",
              body["loginCode"] as? String == "0123456789abcdef0123456789abcdef" else { throw MapFixtureError("LoginExpired", "测试会话失效") }
        switch path {
        case "GetAllLineData": return try json(snapshot.lines.filter { $0.nodes.count >= 2 })
        case "GetAllCrossData": return try json(snapshot.crosses)
        case "GetLogicalNodes": return try json(snapshot.logicalNodes)
        case "Logout": return true
        case "AddLine":
            let line = MapLine(code: nextCode(), owner: "demo", isLocked: false, version: 0, nodes: [])
            remember("新增线路"); snapshot.lines.append(line); return try json(line)
        case "GetLineDetail", "StartToDraw":
            let line = try line(body)
            if path == "StartToDraw" { try editable(line) }
            return try json(line)
        case "CheckShapeIsOKThenSave":
            let old = try versionedLine(body); try editable(old)
            let points: [MapLinePoint] = try decode(body, "nodes")
            guard points.enumerated().allSatisfy({ $0.element.lineCode == old.code && $0.element.order == $0.offset }) else {
                throw MapFixtureError("InvalidShape", "节点必须保留所属线路与连续序号")
            }
            let changed = replacing(old, nodes: points)
            if let problem = MapLineDraft(line: changed).validationMessage { throw MapFixtureError("InvalidShape", problem) }
            remember("保存线路"); replace(changed); rebuildPositions(); return try json(changed)
        case "FindNodePosition":
            _ = try versionedLine(body)
            let points: [MapLinePoint] = try decode(body, "nodes")
            let order = try integer(body, "nodeOrder")
            guard points.indices.contains(order) else { throw MapFixtureError("InvalidNodeOrder", "节点序号无效") }
            return try json(MapNodePositionProposal(nodeOrder: order, x: Int(try number(body, "targetX").rounded()), y: Int(try number(body, "targetY").rounded())))
        case "SetLineProperty":
            let old = try versionedLine(body); try editable(old)
            let properties: MapLineProperties = try decode(body, "properties")
            guard properties.roadName.utf16.count <= 15, properties.roadDetail.utf16.count <= 127,
                  (5...500).contains(properties.speed), properties.passInDirection == 1,
                  [0, 1].contains(properties.passInOpposeDirection) else { throw MapFixtureError("InvalidProperties", "线路属性无效") }
            let changed = replacing(old, properties: properties)
            remember("保存线路属性"); replace(changed); rebuildPositions(); return try json(changed)
        case "LockLine":
            let old = try versionedLine(body)
            let changed = replacing(old, isLocked: !old.isLocked)
            remember("切换线路锁定"); replace(changed); return try json(changed)
        case "ReverseLine":
            let old = try versionedLine(body); try editable(old)
            let points = renumber(Array(old.nodes.reversed()), code: old.code)
            let changed = replacing(old, nodes: points)
            remember("反转线路"); replace(changed); rebuildPositions(); return try json(changed)
        case "RemoveLine":
            let old = try versionedLine(body); try editable(old)
            remember("删除线路"); snapshot.lines.removeAll { $0.code == old.code }
            snapshot.crosses.removeAll { $0.key.roadCode1 == old.code || $0.key.roadCode2 == old.code }
            rebuildPositions(); return true
        case "SplitLine":
            let old = try versionedLine(body); try editable(old)
            let index = try integer(body, "cutBeforeOrder")
            guard index >= 2, index <= old.nodes.count - 2 else { throw MapFixtureError("InvalidSplit", "两侧都需要至少两个节点") }
            let first = replacing(old, nodes: renumber(Array(old.nodes[..<index]), code: old.code))
            let code = nextCode()
            let second = MapLine(code: code, owner: "demo", isLocked: false, version: 0,
                                 nodes: renumber(Array(old.nodes[index...]), code: code), properties: old.properties)
            remember("拆分线路"); replace(first); snapshot.lines.append(second); calculateCrosses(); rebuildPositions()
            return try json(MapLineTopologyResult(lines: [first, second], removedCodes: [], adjustedGridSteps: 0))
        case "GetMergePlans", "MergeLines":
            let first = try line(code: string(body, "firstCode")), second = try line(code: string(body, "secondCode"))
            try version(first.version, body, "firstVersion"); try version(second.version, body, "secondVersion")
            try editable(first); try editable(second)
            guard first.code != second.code, let a = first.nodes.last, let b = second.nodes.first else { throw MapFixtureError("InvalidMerge", "请选择两条不同线路") }
            let plan = MapMergePlan(firstX: a.x, firstY: a.y, secondX: b.x, secondY: b.y,
                                    directionX: b.x == a.x ? 0 : b.x > a.x ? 1 : -1,
                                    directionY: b.y == a.y ? 0 : b.y > a.y ? 1 : -1,
                                    firstCorner: first.nodes.count - 1, secondCorner: 0, adjustedGridSteps: 0)
            if path == "GetMergePlans" { return try json(MapMergePreview(first: first, second: second, plans: [plan])) }
            guard try integer(body, "firstX") == a.x, try integer(body, "firstY") == a.y,
                  try integer(body, "secondX") == b.x, try integer(body, "secondY") == b.y else { throw MapFixtureError("VersionConflict", "合并预览已变化") }
            let combined = first.nodes + Array(second.nodes.dropFirst(a.x == b.x && a.y == b.y ? 1 : 0))
            let changed = replacing(first, nodes: renumber(Array(combined), code: first.code))
            if let problem = MapLineDraft(line: changed).validationMessage { throw MapFixtureError("InvalidShape", problem) }
            remember("合并线路"); replace(changed); snapshot.lines.removeAll { $0.code == second.code }; calculateCrosses(); rebuildPositions()
            return try json(MapLineTopologyResult(lines: [changed], removedCodes: [second.code], adjustedGridSteps: 0))
        case "PasteLine":
            let source: MapLineCopyData = try decode(body, "source")
            let original = try line(code: source.code)
            guard MapLineCopyData(line: original) == source, let anchor = original.nodes.first else { throw MapFixtureError("VersionConflict", "副本源线路已改变") }
            let dx = try integer(body, "x") - anchor.x, dy = try integer(body, "y") - anchor.y
            let code = nextCode()
            let result = MapLine(code: code, owner: "demo", isLocked: original.isLocked, version: 0,
                                 nodes: translate(original.nodes, code: code, dx: dx, dy: dy), properties: original.properties)
            guard result.isValidGeometry else { throw MapFixtureError("OutOfBounds", "粘贴位置超出地图") }
            remember("复制线路"); snapshot.lines.append(result); calculateCrosses(); rebuildPositions()
            return try json(MapLinePasteResult(line: result, map: snapshot))
        case "CalculateCross":
            let old = snapshot
            calculateCrosses()
            if old != snapshot { history.append(("计算交点", old)) }
            return try json(MapCrossCalculationProgress(canContinue: false, remainingSegments: 0, crossCount: snapshot.crosses.count))
        case "EditCross":
            let key: MapCrossKey = try decode(body, "cross")
            guard let index = snapshot.crosses.firstIndex(where: { $0.key == key }) else { throw MapFixtureError("CrossNotFound", "交点已不存在") }
            let old = snapshot.crosses[index]; try version(old.version, body)
            let state = try integer(body, "state")
            guard (-1...3).contains(state) else { throw MapFixtureError("InvalidCrossState", "交点状态无效") }
            if state != -1 && snapshot.logicalNodes.contains(where: { contains($0, old.x, old.y) }) { throw MapFixtureError("LogicalNodeCrossNotDisconnected", "LN 内交点必须不连通") }
            let changed = MapCross(key: key, roadOrder1: old.roadOrder1, roadOrder2: old.roadOrder2,
                                   roadVersion1: old.roadVersion1, roadVersion2: old.roadVersion2, state: state,
                                   version: old.version + 1, percent1: old.percent1, percent2: old.percent2)
            remember("设置交点"); snapshot.crosses[index] = changed; return try json(changed)
        case "AddLogicalNode", "AddLogicalNodeWithOperandKind":
            let size = try integer(body, "sideLength"), x = try number(body, "x"), y = try number(body, "y")
            var properties: MapNodeProperties = try decode(body, "properties")
            let code = nextCode()
            if let parentCode = body["instanceParentCode"] as? String {
                let parent = try node(code: parentCode)
                guard size == 10, MapNodeEditorRules.canInstantiate(parent) else { throw MapFixtureError("InstanceParentNotFound", "所属类无效") }
                properties.value = MapNodeEditorRules.lowercase(parent.properties.value) + "(id=\(code))"
            }
            properties = normalized(properties, size: size, creating: true, code: code)
            let result = MapLogicalNode(code: code, owner: "demo", version: 0, x: x, y: y, sideLength: size,
                                        properties: properties, positions: [], canEdit: true)
            try validateNode(result)
            remember("新增逻辑节点"); snapshot.logicalNodes.append(result); rebuildPositions()
            return try json(try node(code: code))
        case "UpdateLogicalNode", "UpdateLogicalNodeWithOperandKind":
            let old = try versionedNode(body)
            let properties = MapNodeProperties(value: try string(body, "value"), info: try string(body, "info"),
                                               logicLanguage: try string(body, "logicLanguage"), operandKind: try string(body, "operandKind"))
            let changed = replacing(old, properties: normalized(properties, size: old.sideLength, creating: false, code: old.code))
            try validateNode(changed)
            remember("保存逻辑节点"); replace(changed)
            if old.sideLength == 6 && old.properties.logicLanguage != changed.properties.logicLanguage {
                snapshot.logicalNodes = snapshot.logicalNodes.map { other in
                    guard other.sideLength == 4, MapNodeEditorRules.branchSource(value: other.properties.value, logic: other.properties.logicLanguage) == old.properties.logicLanguage else { return other }
                    var properties = other.properties
                    properties.logicLanguage = (properties.value == "True" ? "" : "¬") + changed.properties.logicLanguage
                    return replacing(other, properties: properties)
                }
            }
            if old.sideLength == 12 && old.properties.value != changed.properties.value {
                snapshot.logicalNodes = snapshot.logicalNodes.map { other in
                    guard other.sideLength == 10, MapNodeEditorRules.instanceParent(other.properties.value) == old.properties.value,
                          let open = other.properties.value.firstIndex(of: "(") else { return other }
                    var properties = other.properties
                    properties.value = MapNodeEditorRules.lowercase(changed.properties.value) + String(properties.value[open...])
                    properties.logicLanguage = MapNodeEditorRules.instanceExpression(properties.value)
                    return replacing(other, properties: properties)
                }
            }
            return try json(changed)
        case "MoveLogicalNode":
            let old = try versionedNode(body)
            let changed = replacing(old, x: try number(body, "x"), y: try number(body, "y"))
            try validateNode(changed)
            remember("移动逻辑节点"); replace(changed); rebuildPositions(); return try json(try node(code: old.code))
        case "RemoveLogicalNode":
            let old = try versionedNode(body)
            if old.sideLength == 12 && snapshot.logicalNodes.contains(where: { $0.sideLength == 10 && MapNodeEditorRules.instanceParent($0.properties.value) == old.properties.value }) {
                throw MapFixtureError("LogicalNodeHasInstances", "请先删除该类的实例")
            }
            remember("删除逻辑节点"); snapshot.logicalNodes.removeAll { $0.code == old.code }
            if old.sideLength == 6 {
                snapshot.logicalNodes = snapshot.logicalNodes.map { other in
                    guard other.sideLength == 4, MapNodeEditorRules.branchSource(value: other.properties.value, logic: other.properties.logicLanguage) == old.properties.logicLanguage else { return other }
                    var properties = other.properties; properties.logicLanguage = ""; return replacing(other, properties: properties)
                }
            }
            return true
        case "CalculateLogicalNode":
            try require(body, ["incremental"])
            guard body["incremental"] as? Bool == true else { throw MapFixtureError("InvalidRequest", "Expected incremental LN calculation") }
            if let after = body["afterCode"], !(after is String) { throw MapFixtureError("InvalidRequest", "Invalid LN cursor") }
            rebuildPositions()
            return try json(MapLogicalNodeCalculationProgress(canContinue: false, remainingNodes: 0, nodeCount: snapshot.logicalNodes.count, nextCode: nil))
        case "PreviewLogicalNodeConnection":
            let source: MapLogicalNodeConnectionAnchor = try decode(body, "source"), target: MapLogicalNodeConnectionAnchor = try decode(body, "target")
            let kind: MapLogicalNodeConnectionKind = try decode(body, "kind")
            try anchor(source); try anchor(target)
            guard source.code != target.code else { throw MapFixtureError("InvalidConnection", "请选择两个不同 LN") }
            let code = nextCode()
            let sx = Int(source.x), sy = Int(source.y), tx = Int(target.x), ty = Int(target.y)
            var points: [MapLinePoint]
            if source.y == target.y {
                // The aligned fixture nodes are crossed by an integer lane;
                // the endpoints stay outside both LN squares, as in Server plans.
                let forward = source.x < target.x
                let firstX = forward ? Int(floor(source.x - Double(source.sideLength) / 2)) : Int(ceil(source.x + Double(source.sideLength) / 2))
                let lastX = forward ? Int(ceil(target.x + Double(target.sideLength) / 2)) : Int(floor(target.x - Double(target.sideLength) / 2))
                let lane = Int(ceil(source.y))
                points = [MapLinePoint(lineCode: code, order: 0, x: firstX, y: lane),
                          MapLinePoint(lineCode: code, order: 1, x: lastX, y: lane)]
            } else {
                points = [MapLinePoint(lineCode: code, order: 0, x: sx, y: sy)]
                if sx != tx && sy != ty { points.append(MapLinePoint(lineCode: code, order: points.count, x: tx, y: sy)) }
                points.append(MapLinePoint(lineCode: code, order: points.count, x: tx, y: ty))
            }
            let result = MapLogicalNodeConnectionPlan(source: source, target: target, lineCode: code, nodes: points, kind: kind, join: nil, continuation: [])
            pendingConnection = result; return try json(result)
        case "SaveLogicalNodeConnection":
            let plan: MapLogicalNodeConnectionPlan = try decode(body, "plan")
            guard plan == pendingConnection else { throw MapFixtureError("VersionConflict", "连接预览已失效") }
            try anchor(plan.source); try anchor(plan.target)
            let line = MapLine(code: plan.lineCode, owner: "demo", isLocked: false, version: 0, nodes: plan.nodes)
            remember("连接逻辑节点"); snapshot.lines.append(line); calculateCrosses(); rebuildPositions(); pendingConnection = nil
            return try json(MapLogicalNodeConnectionResult(line: line, map: snapshot, disconnectedCrosses: 0))
        case "SelectMapArea":
            let bounds: MapAreaBounds = try decode(body, "bounds")
            guard bounds.isValid else { throw MapFixtureError("InvalidBounds", "框选范围无效") }
            return try json(selection(bounds))
        case "MoveMapArea", "PasteMapArea", "DeleteMapArea":
            let expected: MapAreaSelection = try decode(body, "selection")
            // Like MapAreaMoveService.ReadSelection, the request is a version
            // token. Reload authoritative objects; clipboard display metadata
            // (positions/canEdit) and posted properties are not source edits.
            let token = try readSelection(expected, sourceObjectsOnly: path == "PasteMapArea")
            if path == "DeleteMapArea" {
                remember("删除选区")
                let roads = Set(token.lines.map(\.code)), nodes = Set(token.logicalNodes.map(\.code))
                snapshot.lines.removeAll { roads.contains($0.code) }; snapshot.logicalNodes.removeAll { nodes.contains($0.code) }
                calculateCrosses(); rebuildPositions(); return try json(snapshot)
            }
            let dx = try integer(body, "deltaX"), dy = try integer(body, "deltaY")
            if path == "MoveMapArea" {
                let movedLines = token.lines.map { replacing($0, nodes: translate($0.nodes, code: $0.code, dx: dx, dy: dy)) }
                let movedNodes = token.logicalNodes.map { replacing($0, x: $0.x + Double(dx), y: $0.y + Double(dy)) }
                guard movedLines.allSatisfy(\.isValidGeometry), movedNodes.allSatisfy(\.isValidGeometry) else { throw MapFixtureError("OutOfBounds", "选区超出地图范围") }
                remember("移动选区")
                movedLines.forEach { replace($0) }; movedNodes.forEach { replace($0) }
                let movedCodes = Set(movedLines.map(\.code))
                snapshot.crosses = snapshot.crosses.map { cross in
                    guard movedCodes.contains(cross.key.roadCode1) && movedCodes.contains(cross.key.roadCode2) else { return cross }
                    return shiftedCross(cross, roads: [:], dx: dx, dy: dy)
                }
                calculateCrosses(); rebuildPositions(); return try json(snapshot)
            }
            guard !token.logicalNodes.contains(where: { $0.sideLength == 18 }) else { throw MapFixtureError("StartLogicalNodeNotCopyable", "LN18 开始节点不能复制") }
            var roadCodes: [String: String] = [:], nodeCodes: [String: String] = [:]
            var added = MapSnapshot()
            for old in token.lines {
                let code = nextCode(); roadCodes[old.code] = code
                added.lines.append(MapLine(code: code, owner: "demo", isLocked: old.isLocked, version: 0,
                                           nodes: translate(old.nodes, code: code, dx: dx, dy: dy), properties: old.properties))
            }
            for old in token.logicalNodes {
                let code = nextCode(); nodeCodes[old.code] = code
                added.logicalNodes.append(MapLogicalNode(code: code, owner: "demo", version: 0,
                    x: old.x + Double(dx), y: old.y + Double(dy), sideLength: old.sideLength,
                    properties: normalized(old.properties, size: old.sideLength, creating: true, code: code), positions: [], canEdit: true))
            }
            guard added.lines.allSatisfy(\.isValidGeometry), added.logicalNodes.allSatisfy(\.isValidGeometry) else { throw MapFixtureError("OutOfBounds", "副本超出地图范围") }
            added.crosses = token.crosses.map { shiftedCross($0, roads: roadCodes, dx: dx, dy: dy) }
            remember("复制选区"); snapshot.lines += added.lines; snapshot.logicalNodes += added.logicalNodes; snapshot.crosses += added.crosses
            calculateCrosses(); rebuildPositions()
            return try json(MapAreaPasteResult(added: added, map: snapshot, logicalNodeCodes: nodeCodes, roadCodes: roadCodes, notes: []))
        case "PreviewFlowDiagram", "ImportFlowDiagram":
            let text = try string(body, "text"), x = try number(body, "x"), y = try number(body, "y")
            let result = try flow(text: text, x: x, y: y, importing: path == "ImportFlowDiagram")
            return try json(result)
        case "UndoMap":
            let id = try string(body, "requestId")
            guard !id.isEmpty else { throw MapFixtureError("InvalidUndoRequest", "撤销需要请求标识") }
            if let cached = undoReplies[id] { return try json(cached) }
            guard let previous = history.popLast() else { throw MapFixtureError("NothingToUndo", "没有可撤销操作") }
            snapshot = previous.1
            let result = MapUndoResult(operation: previous.0, map: snapshot); undoReplies[id] = result
            return try json(result)
        default: throw MapFixtureError("UnexpectedEndpoint", "Unexpected editing endpoint: \(path)")
        }
    }

    private func require(_ body: [String: Any], _ names: Set<String>) throws {
        guard names.isSubset(of: Set(body.keys)) else { throw MapFixtureError("InvalidRequest", "Missing fields: \(names.subtracting(body.keys).sorted())") }
    }
    private func string(_ body: [String: Any], _ key: String) throws -> String {
        guard let result = body[key] as? String else { throw MapFixtureError("InvalidRequest", "Missing string \(key)") }; return result
    }
    private func number(_ body: [String: Any], _ key: String) throws -> Double {
        guard let result = body[key] as? NSNumber, result.doubleValue.isFinite else { throw MapFixtureError("InvalidRequest", "Missing number \(key)") }; return result.doubleValue
    }
    private func integer(_ body: [String: Any], _ key: String) throws -> Int {
        let value = try number(body, key)
        guard value.rounded() == value, abs(value) < Double(Int.max) else { throw MapFixtureError("InvalidRequest", "Expected integer \(key)") }; return Int(value)
    }
    private func decode<T: Decodable>(_ body: [String: Any], _ key: String) throws -> T {
        guard let value = body[key] else { throw MapFixtureError("InvalidRequest", "Missing payload \(key)") }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
    private func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]) }
    private func version(_ actual: Int64, _ body: [String: Any], _ key: String = "version") throws {
        guard Int64(try integer(body, key)) == actual else { throw MapFixtureError("VersionConflict", "对象已改变，请刷新") }
    }
    private func line(_ body: [String: Any]) throws -> MapLine { try line(code: string(body, "lineCode")) }
    private func line(code: String) throws -> MapLine {
        guard let value = snapshot.lines.first(where: { $0.code == code }) else { throw MapFixtureError("LineNotFound", "线路不存在") }; return value
    }
    private func versionedLine(_ body: [String: Any]) throws -> MapLine { let result = try line(body); try version(result.version, body); return result }
    private func editable(_ line: MapLine) throws { if line.isLocked { throw MapFixtureError("LineIsLocked", "请先解锁线路") } }
    private func node(code: String) throws -> MapLogicalNode {
        guard let value = snapshot.logicalNodes.first(where: { $0.code == code }) else { throw MapFixtureError("LogicalNodeNotFound", "节点不存在") }; return value
    }
    private func versionedNode(_ body: [String: Any]) throws -> MapLogicalNode { let result = try node(code: string(body, "code")); try version(result.version, body); return result }
    private func anchor(_ value: MapLogicalNodeConnectionAnchor) throws {
        guard value == MapLogicalNodeConnectionAnchor(node: try node(code: value.code)) else { throw MapFixtureError("VersionConflict", "LN 几何已改变") }
    }
    private func nextCode() -> String {
        serial += 1
        return "ZZZZZZZZ" + String(UnicodeScalar(65 + serial / 26 % 26)!) + String(UnicodeScalar(65 + serial % 26)!)
    }
    private func remember(_ operation: String) { history.append((operation, snapshot)) }
    private func replace(_ line: MapLine) { if let index = snapshot.lines.firstIndex(where: { $0.code == line.code }) { snapshot.lines[index] = line } }
    private func replace(_ node: MapLogicalNode) { if let index = snapshot.logicalNodes.firstIndex(where: { $0.code == node.code }) { snapshot.logicalNodes[index] = node } }
    private func replacing(_ old: MapLine, nodes: [MapLinePoint]? = nil, properties: MapLineProperties? = nil, isLocked: Bool? = nil) -> MapLine {
        MapLine(code: old.code, owner: old.owner, isLocked: isLocked ?? old.isLocked, version: old.version + 1,
                nodes: nodes ?? old.nodes, properties: properties ?? old.properties)
    }
    private func replacing(_ old: MapLogicalNode, properties: MapNodeProperties? = nil, x: Double? = nil, y: Double? = nil) -> MapLogicalNode {
        MapLogicalNode(code: old.code, owner: old.owner, version: old.version + 1, x: x ?? old.x, y: y ?? old.y,
                       sideLength: old.sideLength, properties: properties ?? old.properties, positions: old.positions, canEdit: old.canEdit)
    }
    private func renumber(_ points: [MapLinePoint], code: String) -> [MapLinePoint] {
        points.enumerated().map { MapLinePoint(lineCode: code, order: $0.offset, x: $0.element.x, y: $0.element.y) }
    }
    private func translate(_ points: [MapLinePoint], code: String, dx: Int, dy: Int) -> [MapLinePoint] {
        points.enumerated().map { MapLinePoint(lineCode: code, order: $0.offset, x: $0.element.x + dx, y: $0.element.y + dy) }
    }
    private func contains(_ node: MapLogicalNode, _ x: Double, _ y: Double) -> Bool { x >= node.left && x <= node.right && y >= node.bottom && y <= node.top }
    private func normalized(_ p: MapNodeProperties, size: Int, creating: Bool, code: String) -> MapNodeProperties {
        var result = p
        if size == 8 { result.logicLanguage = MapNodeEditorRules.relationLogic(result.value) }
        if size == 10 { result.value = MapNodeEditorRules.normalizeInstance(result.value); result.logicLanguage = MapNodeEditorRules.instanceExpression(result.value) }
        if size == 6 {
            let requested = MapNodeEditorRules.operandLogic(result.logicLanguage.isEmpty ? "LN_" + code : result.logicLanguage, kind: result.operandKind)
            result.logicLanguage = creating ? unique(requested, among: snapshot.logicalNodes.filter { $0.sideLength == 6 }.map { $0.properties.logicLanguage }) : requested
        }
        if size == 12 {
            let requested = MapNodeEditorRules.uppercase(result.value)
            result.value = creating ? unique(requested, among: snapshot.logicalNodes.filter { $0.sideLength == 12 }.map { $0.properties.value }) : requested
            if result.logicLanguage.isEmpty { result.logicLanguage = result.value }
        }
        return result
    }
    private func unique(_ requested: String, among used: [String]) -> String {
        var value = requested, suffix = 1
        while used.contains(value) { value = requested + String(suffix); suffix += 1 }
        return value
    }
    private func validateNode(_ value: MapLogicalNode) throws {
        guard value.isValidGeometry else { throw MapFixtureError("InvalidLogicalNodeCoordinate", "LN 几何无效") }
        if value.sideLength == 18 && snapshot.logicalNodes.contains(where: { $0.sideLength == 18 && $0.code != value.code }) { throw MapFixtureError("StartLogicalNodeExists", "全图只能有一个开始节点") }
        if snapshot.logicalNodes.contains(where: { $0.code != value.code && value.left <= $0.right && value.right >= $0.left && value.bottom <= $0.top && value.top >= $0.bottom }) {
            throw MapFixtureError("LogicalNodesTouchOrOverlap", "逻辑节点不能重叠或接触")
        }
    }
    private func selection(_ bounds: MapAreaBounds) -> MapAreaSelection {
        func inside(_ x: Double, _ y: Double) -> Bool { x >= bounds.left && x <= bounds.right && y >= bounds.bottom && y <= bounds.top }
        let lines = snapshot.lines.filter { $0.nodes.count >= 2 && $0.nodes.allSatisfy { inside(Double($0.x), Double($0.y)) } }
        let nodes = snapshot.logicalNodes.filter { inside($0.left, $0.bottom) && inside($0.right, $0.top) }
        let codes = Set(lines.map(\.code))
        return MapAreaSelection(bounds: bounds, lines: lines, logicalNodes: nodes,
            crosses: snapshot.crosses.filter { codes.contains($0.key.roadCode1) && codes.contains($0.key.roadCode2) && inside($0.x, $0.y) })
    }
    private func readSelection(_ expected: MapAreaSelection, sourceObjectsOnly: Bool) throws -> MapAreaSelection {
        guard expected.bounds.isValid else { throw MapFixtureError("InvalidBounds", "框选范围无效") }
        let entire = selection(expected.bounds)
        let requestedRoads = Set(expected.lines.map(\.code)), requestedNodes = Set(expected.logicalNodes.map(\.code))
        let roads = sourceObjectsOnly ? entire.lines.filter { requestedRoads.contains($0.code) } : entire.lines
        let nodes = sourceObjectsOnly ? entire.logicalNodes.filter { requestedNodes.contains($0.code) } : entire.logicalNodes
        let selectedRoads = Set(roads.map(\.code))
        let crosses = entire.crosses.filter { selectedRoads.contains($0.key.roadCode1) && selectedRoads.contains($0.key.roadCode2) }
        guard !roads.isEmpty || !nodes.isEmpty else { throw MapFixtureError("EmptySelection", "请选择完整的线路或 LN") }
        for road in roads {
            guard road.owner == "demo" else { throw MapFixtureError("NotOwner", "当前用户不能修改这条线路") }
            try editable(road)
        }
        for node in nodes {
            guard node.canEdit ?? (node.owner == "demo") else { throw MapFixtureError("NotOwner", "没有操作 LN 的权限") }
        }
        guard sameVersions(expected.lines, roads, key: { $0.code }, version: { $0.version }),
              sameVersions(expected.logicalNodes, nodes, key: { $0.code }, version: { $0.version }),
              sameVersions(expected.crosses, crosses, key: { $0.key }, version: { $0.version }) else {
            throw MapFixtureError("SelectionChanged", "框选对象、线路锁定或 Cross 设置已改变，请重新框选；未提交操作。")
        }
        return MapAreaSelection(bounds: expected.bounds, lines: roads, logicalNodes: nodes, crosses: crosses)
    }

    private func sameVersions<T, Key: Hashable>(_ expected: [T], _ current: [T],
                                               key: (T) -> Key, version: (T) -> Int64) -> Bool {
        guard expected.count == current.count else { return false }
        var versions: [Key: Int64] = [:]
        for item in expected {
            guard versions.updateValue(version(item), forKey: key(item)) == nil else { return false }
        }
        return current.allSatisfy { versions[key($0)] == version($0) }
    }
    private func shiftedCross(_ old: MapCross, roads: [String: String], dx: Int, dy: Int) -> MapCross {
        let first = roads[old.key.roadCode1] ?? old.key.roadCode1, second = roads[old.key.roadCode2] ?? old.key.roadCode2
        let reversed = first < second
        let key = MapCrossKey(roadCode1: max(first, second), roadCode2: min(first, second),
                              position: MapCrossPosition(x2: old.key.position.x2 + 2 * dx, y2: old.key.position.y2 + 2 * dy))
        return MapCross(key: key, roadOrder1: reversed ? old.roadOrder2 : old.roadOrder1,
                         roadOrder2: reversed ? old.roadOrder1 : old.roadOrder2, roadVersion1: 0, roadVersion2: 0,
                         state: reversed && [2, 3].contains(old.state) ? 5 - old.state : old.state,
                         version: old.version + 1, percent1: reversed ? old.percent2 : old.percent1,
                         percent2: reversed ? old.percent1 : old.percent2)
    }
    private func calculateCrosses() {
        let previous = Dictionary(snapshot.crosses.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var result: [MapCrossKey: MapCross] = [:]
        let roads = snapshot.lines.filter { $0.nodes.count >= 2 }.sorted { $0.code > $1.code }
        for i in roads.indices {
            for j in roads.indices where j > i {
                let first = roads[i], second = roads[j]
                for a in 0..<(first.nodes.count - 1) {
                    for b in 0..<(second.nodes.count - 1) {
                        let p = first.nodes[a], q = first.nodes[a + 1], r = second.nodes[b], s = second.nodes[b + 1]
                        let dx = Double(q.x - p.x), dy = Double(q.y - p.y), ex = Double(s.x - r.x), ey = Double(s.y - r.y)
                        let denominator = dx * ey - dy * ex
                        if denominator == 0 { continue }
                        let rx = Double(r.x - p.x), ry = Double(r.y - p.y)
                        let t = (rx * ey - ry * ex) / denominator, u = (rx * dy - ry * dx) / denominator
                        if t < 0 || t > 1 || u < 0 || u > 1 { continue }
                        let x = Double(p.x) + t * dx, y = Double(p.y) + t * dy
                        if x.rounded() != x || y.rounded() != y { continue }
                        let key = MapCrossKey(roadCode1: first.code, roadCode2: second.code, position: MapCrossPosition(x2: Int(x) * 2, y2: Int(y) * 2))
                        if result[key] != nil { continue }
                        let old = previous[key]
                        result[key] = MapCross(key: key, roadOrder1: a, roadOrder2: b, roadVersion1: first.version, roadVersion2: second.version,
                            state: old?.state ?? (snapshot.logicalNodes.contains(where: { contains($0, x, y) }) ? -1 : 0), version: old?.version ?? 0, percent1: t, percent2: u)
                    }
                }
            }
        }
        snapshot.crosses = result.values.sorted { $0.key.roadCode1 + $0.key.roadCode2 < $1.key.roadCode1 + $1.key.roadCode2 }
    }
    private func rebuildPositions() {
        snapshot.logicalNodes = snapshot.logicalNodes.map { node in
            var positions: [MapNodePosition] = []
            for line in snapshot.lines where line.nodes.count >= 2 {
                for index in 0..<(line.nodes.count - 1) {
                    let a = line.nodes[index], b = line.nodes[index + 1]
                    let dx = Double(b.x - a.x), dy = Double(b.y - a.y), length = dx * dx + dy * dy
                    guard length > 0 else { continue }
                    let t = ((node.x - Double(a.x)) * dx + (node.y - Double(a.y)) * dy) / length
                    let x = Double(a.x) + t * dx, y = Double(a.y) + t * dy
                    if (0...1).contains(t) && contains(node, x, y) {
                        positions.append(MapNodePosition(logicalNodeCode: node.code, roadCode: line.code, roadOrder: index,
                            roadPercent: t, x: x, y: y, roadVersion: line.version, isChanged: false))
                    }
                }
            }
            guard positions != node.positions else { return node }
            var changed = replacing(node); changed.positions = positions; return changed
        }
    }
    private func flow(text: String, x: Double, y: Double, importing: Bool) throws -> MapFlowDiagramResult {
        guard let data = text.data(using: .utf8), let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["format"] as? String == "argumentmap.flow/1", let definitions = document["ln"] as? [[String: Any]],
              let roads = document["roads"] as? [[String: Any]], let originID = document["origin"] as? String,
              let origin = definitions.first(where: { $0["id"] as? String == originID }), let originAt = origin["at"] as? [Double], originAt.count == 2 else {
            throw MapFixtureError("InvalidFlowDiagram", "流程图 JSON 格式无效")
        }
        let dx = x - originAt[0], dy = y - originAt[1]
        var added = MapSnapshot(), nodeCodes: [String: String] = [:], roadCodes: [String: String] = [:]
        for item in definitions {
            guard let id = item["id"] as? String, let at = item["at"] as? [Double], at.count == 2 else { throw MapFixtureError("InvalidFlowDiagram", "LN 缺少 id/at") }
            let code = nextCode(), size = item["size"] as? Int ?? 12
            let properties = MapNodeProperties(value: item["value"] as? String ?? "逻辑节点", info: item["info"] as? String ?? "",
                logicLanguage: item["logic"] as? String ?? "", operandKind: item["operandKind"] as? String ?? "Custom")
            let node = MapLogicalNode(code: code, owner: "demo", version: 0, x: at[0] + dx, y: at[1] + dy, sideLength: size,
                properties: normalized(properties, size: size, creating: true, code: code), positions: [], canEdit: true)
            try validateNode(node); added.logicalNodes.append(node); nodeCodes[id] = code
        }
        for item in roads {
            guard let id = item["id"] as? String, let points = item["points"] as? [[Double]], points.allSatisfy({ $0.count == 2 }) else { throw MapFixtureError("InvalidFlowDiagram", "Road 缺少 id/points") }
            let code = nextCode()
            let line = MapLine(code: code, owner: "demo", isLocked: false, version: 0,
                nodes: points.enumerated().map { MapLinePoint(lineCode: code, order: $0.offset, x: Int(($0.element[0] + dx).rounded()), y: Int(($0.element[1] + dy).rounded())) },
                properties: MapLineProperties(roadName: item["name"] as? String ?? "", roadDetail: item["info"] as? String ?? "",
                    speed: item["speed"] as? Int ?? 100, passInDirection: 1, passInOpposeDirection: item["direction"] as? String == "both" ? 1 : 0))
            guard line.isValidGeometry else { throw MapFixtureError("InvalidFlowDiagram", "Road 坐标无效") }
            added.lines.append(line); roadCodes[id] = code
        }
        // Preview executes against a temporary snapshot, including the same
        // Cross direction mapping used by import, and never enters undo history.
        let before = snapshot
        defer { if !importing { snapshot = before } }
        snapshot.lines += added.lines; snapshot.logicalNodes += added.logicalNodes
        calculateCrosses(); rebuildPositions()
        for item in document["crosses"] as? [[String: Any]] ?? [] {
            guard let firstID = item["road1"] as? String, let secondID = item["road2"] as? String,
                  let first = roadCodes[firstID], let second = roadCodes[secondID], first != second,
                  let at = item["at"] as? [Double], at.count == 2, let state = item["state"] as? String else {
                throw MapFixtureError("InvalidFlowCross", "Cross 缺少 road1/road2/at/state")
            }
            let cx = at[0] + dx, cy = at[1] + dy
            guard cx.isFinite, cy.isFinite, (0...500_000).contains(cx), (0...500_000).contains(cy),
                  cx.rounded() == cx, cy.rounded() == cy else { throw MapFixtureError("InvalidFlowCross", "Cross 必须位于整数坐标") }
            let key = MapCrossKey(roadCode1: max(first, second), roadCode2: min(first, second),
                                  position: MapCrossPosition(x2: Int(cx) * 2, y2: Int(cy) * 2))
            guard let index = snapshot.crosses.firstIndex(where: { $0.key == key }) else { throw MapFixtureError("CrossNotFound", "指定的两条线路未在此处相交") }
            let value: Int
            switch state {
            case "connected": value = 1
            case "disconnected": value = -1
            case "road1ToRoad2": value = first > second ? 2 : 3
            case "road2ToRoad1": value = first > second ? 3 : 2
            case "unset": value = 0
            default: throw MapFixtureError("InvalidFlowCross", "未知 Cross 状态")
            }
            guard value == -1 || !snapshot.logicalNodes.contains(where: { contains($0, cx, cy) }) else {
                throw MapFixtureError("LogicalNodeCrossNotDisconnected", "LN 内交点必须不连通")
            }
            let old = snapshot.crosses[index]
            snapshot.crosses[index] = MapCross(key: key, roadOrder1: old.roadOrder1, roadOrder2: old.roadOrder2,
                roadVersion1: old.roadVersion1, roadVersion2: old.roadVersion2, state: value,
                version: old.version + 1, percent1: old.percent1, percent2: old.percent2)
        }
        let addedRoads = Set(roadCodes.values), addedNodes = Set(nodeCodes.values)
        added = MapSnapshot(lines: snapshot.lines.filter { addedRoads.contains($0.code) },
            logicalNodes: snapshot.logicalNodes.filter { addedNodes.contains($0.code) },
            crosses: snapshot.crosses.filter { addedRoads.contains($0.key.roadCode1) || addedRoads.contains($0.key.roadCode2) })
        if importing { history.append(("导入流程图", before)) }
        return MapFlowDiagramResult(added: added, map: importing ? snapshot : nil, logicalNodeCodes: nodeCodes, roadCodes: roadCodes, notes: ["UI 测试夹具预览"])
    }
}
#endif
