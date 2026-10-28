import Foundation

extension MapAPI {
    func createLine(session: MapSession) async throws -> MapLine {
        try checkedLine(await post("AddLine", body: OwnerBody(session)))
    }

    func startDrawing(lineCode: String, session: MapSession) async throws -> MapLine {
        try checkedLine(await post("StartToDraw", body: LineAccessBody(lineCode: lineCode, session: session)))
    }

    func lineDetail(lineCode: String, session: MapSession) async throws -> MapLine {
        try checkedLine(await post("GetLineDetail", body: LineAccessBody(lineCode: lineCode, session: session)))
    }

    func saveLine(lineCode: String, version: Int64, nodes: [MapLinePoint], session: MapSession) async throws -> MapLine {
        try checkedLine(await post("CheckShapeIsOKThenSave", body: SaveLineBody(
            lineCode: lineCode, owner: session.userName, version: version, nodes: nodes, loginCode: session.loginCode)))
    }

    func findNodePosition(lineCode: String, version: Int64, nodes: [MapLinePoint], nodeOrder: Int,
                          targetX: Double, targetY: Double, session: MapSession) async throws -> MapNodePositionProposal {
        let proposal: MapNodePositionProposal = try await post("FindNodePosition", body: FindNodeBody(lineCode: lineCode, owner: session.userName,
            version: version, nodes: nodes, nodeOrder: nodeOrder, targetX: targetX, targetY: targetY, loginCode: session.loginCode))
        guard proposal.nodeOrder == nodeOrder, (0...500_000).contains(proposal.x), (0...500_000).contains(proposal.y) else {
            throw MapAPIError(code: "InvalidResponse", message: "服务端返回了不匹配的节点位置，草稿未更改。请重新定位后再试。")
        }
        return proposal
    }

    func deleteLine(lineCode: String, version: Int64, session: MapSession) async throws -> Bool {
        let deleted: Bool = try await post("RemoveLine", body: LineVersionBody(lineCode: lineCode, version: version, session: session))
        guard deleted else { throw editingResponseError() }
        return deleted
    }

    func saveLineProperties(lineCode: String, version: Int64, properties: MapLineProperties, session: MapSession) async throws -> MapLine {
        try checkedLine(await post("SetLineProperty", body: LinePropertiesBody(lineCode: lineCode,
            owner: session.userName, version: version, properties: properties, loginCode: session.loginCode)))
    }

    func toggleLineLock(lineCode: String, version: Int64, session: MapSession) async throws -> MapLine {
        try checkedLine(await post("LockLine", body: LineVersionBody(lineCode: lineCode, version: version, session: session)))
    }

    func reverseLine(lineCode: String, version: Int64, session: MapSession) async throws -> MapLine {
        try checkedLine(await post("ReverseLine", body: LineVersionBody(lineCode: lineCode, version: version, session: session)))
    }

    func splitLine(lineCode: String, version: Int64, cutBeforeOrder: Int, session: MapSession) async throws -> MapLineTopologyResult {
        let result: MapLineTopologyResult = try await post("SplitLine", body: SplitLineBody(lineCode: lineCode,
            owner: session.userName, version: version, cutBeforeOrder: cutBeforeOrder, loginCode: session.loginCode))
        try result.lines.forEach { _ = try checkedLine($0) }
        return result
    }

    func mergePlans(first: MapLine, second: MapLine, session: MapSession) async throws -> MapMergePreview {
        let result: MapMergePreview = try await post("GetMergePlans", body: MergeLinesBody(firstCode: first.code,
            firstVersion: first.version, secondCode: second.code, secondVersion: second.version,
            owner: session.userName, loginCode: session.loginCode))
        _ = try checkedLine(result.first); _ = try checkedLine(result.second)
        return result
    }

    func mergeLines(preview: MapMergePreview, plan: MapMergePlan, session: MapSession) async throws -> MapLineTopologyResult {
        let result: MapLineTopologyResult = try await post("MergeLines", body: ApplyMergeBody(
            firstCode: preview.first.code, firstVersion: preview.first.version,
            secondCode: preview.second.code, secondVersion: preview.second.version, owner: session.userName,
            firstX: plan.firstX, firstY: plan.firstY, secondX: plan.secondX, secondY: plan.secondY, loginCode: session.loginCode))
        try result.lines.forEach { _ = try checkedLine($0) }
        return result
    }

    func pasteLine(source: MapLineCopyData, x: Int, y: Int, session: MapSession) async throws -> MapLinePasteResult {
        let result: MapLinePasteResult = try await post("PasteLine", body: PasteLineBody(owner: session.userName,
            source: source, x: x, y: y, loginCode: session.loginCode))
        _ = try checkedLine(result.line); try checkMap(result.map)
        return result
    }

    /// One server transaction, never an unbounded client-side calculation.
    func calculateCross(session: MapSession) async throws -> MapCrossCalculationProgress {
        try await post("CalculateCross", body: session)
    }

    func editCross(cross: MapCross, state: Int, session: MapSession) async throws -> MapCross {
        try await post("EditCross", body: CrossEditBody(cross: cross.key, owner: session.userName,
            version: cross.version, state: state, loginCode: session.loginCode))
    }

    func createLogicalNode(x: Double, y: Double, sideLength: Int, properties: MapNodeProperties,
                           instanceParentCode: String? = nil, session: MapSession) async throws -> MapLogicalNode {
        let path = sideLength == 6 && properties.operandKind != "Custom" ? "AddLogicalNodeWithOperandKind" : "AddLogicalNode"
        return try checkedNode(await post(path, body: CreateNodeBody(owner: session.userName, x: x, y: y,
            sideLength: sideLength, properties: properties, loginCode: session.loginCode, instanceParentCode: instanceParentCode)))
    }

    func updateLogicalNode(node: MapLogicalNode, properties: MapNodeProperties, session: MapSession) async throws -> MapLogicalNode {
        // The explicit endpoint prevents older servers from silently dropping operandKind.
        try checkedNode(await post("UpdateLogicalNodeWithOperandKind", body: UpdateNodeBody(code: node.code,
            owner: session.userName, version: node.version, value: properties.value, info: properties.info,
            loginCode: session.loginCode, logicLanguage: properties.logicLanguage, operandKind: properties.operandKind)))
    }

    func moveLogicalNode(node: MapLogicalNode, x: Double, y: Double, session: MapSession) async throws -> MapLogicalNode {
        try checkedNode(await post("MoveLogicalNode", body: MoveNodeBody(code: node.code, owner: session.userName,
            version: node.version, x: x, y: y, loginCode: session.loginCode)))
    }

    func deleteLogicalNode(node: MapLogicalNode, session: MapSession) async throws -> Bool {
        let deleted: Bool = try await post("RemoveLogicalNode", body: DeleteNodeBody(code: node.code,
            owner: session.userName, version: node.version, loginCode: session.loginCode))
        guard deleted else { throw editingResponseError() }
        return deleted
    }

    /// Pass nextCode from the previous response; nil begins a new incremental scan.
    func calculateLogicalNodes(afterCode: String? = nil, session: MapSession) async throws -> MapLogicalNodeCalculationProgress {
        try await post("CalculateLogicalNode", body: CalculateNodesBody(userName: session.userName,
            loginCode: session.loginCode, incremental: true, afterCode: afterCode))
    }

    func previewLogicalNodeConnection(source: MapLogicalNode, target: MapLogicalNode,
                                      kind: MapLogicalNodeConnectionKind, session: MapSession) async throws -> MapLogicalNodeConnectionPlan {
        let result: MapLogicalNodeConnectionPlan = try await post("PreviewLogicalNodeConnection", body: PreviewConnectionBody(
            owner: session.userName, source: MapLogicalNodeConnectionAnchor(node: source),
            target: MapLogicalNodeConnectionAnchor(node: target), loginCode: session.loginCode, kind: kind), timeoutInterval: 180)
        let plannedLine = MapLine(code: result.lineCode, owner: session.userName, isLocked: false,
                                  version: 0, nodes: result.nodes)
        guard result.source == MapLogicalNodeConnectionAnchor(node: source),
              result.target == MapLogicalNodeConnectionAnchor(node: target),
              plannedLine.nodes.count >= 2, plannedLine.isValidGeometry,
              result.join.map({ join in
                  MapCrossKey(roadCode1: max(result.lineCode, join.roadCode),
                              roadCode2: min(result.lineCode, join.roadCode), position: join.position).isValid
              }) ?? true else { throw editingResponseError() }
        return result
    }

    func saveLogicalNodeConnection(plan: MapLogicalNodeConnectionPlan, session: MapSession) async throws -> MapLogicalNodeConnectionResult {
        let result: MapLogicalNodeConnectionResult = try await post("SaveLogicalNodeConnection",
            body: SaveConnectionBody(owner: session.userName, plan: plan, loginCode: session.loginCode), timeoutInterval: 120)
        _ = try checkedLine(result.line); try checkMap(result.map)
        return result
    }

    func selectMapArea(bounds: MapAreaBounds, session: MapSession) async throws -> MapAreaSelection {
        let result: MapAreaSelection = try await post("SelectMapArea", body: SelectAreaBody(owner: session.userName,
            bounds: bounds, loginCode: session.loginCode), timeoutInterval: 120)
        guard result.bounds.isValid else { throw editingResponseError() }
        try checkMap(result.snapshot)
        return result
    }

    func moveMapArea(selection: MapAreaSelection, deltaX: Int, deltaY: Int, session: MapSession) async throws -> MapSnapshot {
        let result: MapSnapshot = try await post("MoveMapArea", body: TransformAreaBody(owner: session.userName,
            selection: selection, deltaX: deltaX, deltaY: deltaY, loginCode: session.loginCode), timeoutInterval: 120)
        try checkMap(result)
        return result
    }

    func deleteMapArea(selection: MapAreaSelection, session: MapSession) async throws -> MapSnapshot {
        let result: MapSnapshot = try await post("DeleteMapArea", body: DeleteAreaBody(owner: session.userName,
            selection: selection, loginCode: session.loginCode), timeoutInterval: 120)
        try checkMap(result)
        return result
    }

    func pasteMapArea(selection: MapAreaSelection, deltaX: Int, deltaY: Int, session: MapSession) async throws -> MapAreaPasteResult {
        let result: MapAreaPasteResult = try await post("PasteMapArea", body: TransformAreaBody(owner: session.userName,
            selection: selection, deltaX: deltaX, deltaY: deltaY, loginCode: session.loginCode), timeoutInterval: 120)
        try checkMap(result.added); try checkMap(result.map)
        return result
    }

    func previewFlowDiagram(text: String, x: Double, y: Double, session: MapSession) async throws -> MapFlowDiagramResult {
        try await flowDiagram(path: "PreviewFlowDiagram", text: text, x: x, y: y, session: session)
    }

    func importFlowDiagram(text: String, x: Double, y: Double, session: MapSession) async throws -> MapFlowDiagramResult {
        let result = try await flowDiagram(path: "ImportFlowDiagram", text: text, x: x, y: y, session: session)
        guard result.map != nil else { throw editingResponseError() }
        return result
    }

    /// The caller retains requestID when the response is uncertain, including
    /// network/HTTP/database errors and expired sessions. A retry must reuse it.
    func undoMap(requestID: String, session: MapSession) async throws -> MapUndoResult {
        let result: MapUndoResult = try await post("UndoMap", body: UndoBody(userName: session.userName,
            loginCode: session.loginCode, requestId: requestID))
        try checkMap(result.map)
        return result
    }

    private func flowDiagram(path: String, text: String, x: Double, y: Double, session: MapSession) async throws -> MapFlowDiagramResult {
        let result: MapFlowDiagramResult = try await post(path, body: FlowBody(owner: session.userName,
            text: text, x: x, y: y, loginCode: session.loginCode), timeoutInterval: 120)
        try checkMap(result.added)
        if let map = result.map { try checkMap(map) }
        return result
    }

    private func checkedLine(_ line: MapLine) throws -> MapLine {
        guard line.isValidGeometry else { throw editingResponseError() }
        return line
    }

    private func checkedNode(_ node: MapLogicalNode) throws -> MapLogicalNode {
        guard node.isValidGeometry else { throw editingResponseError() }
        return node
    }

    private func checkMap(_ map: MapSnapshot) throws {
        guard map.lines.allSatisfy(\.isValidGeometry), map.logicalNodes.allSatisfy(\.isValidGeometry),
              Set(map.lines.map(\.code)).count == map.lines.count,
              Set(map.logicalNodes.map(\.code)).count == map.logicalNodes.count,
              Set(map.crosses.map(\.key)).count == map.crosses.count else { throw editingResponseError() }
    }

    private func editingResponseError() -> MapAPIError {
        MapAPIError(code: "InvalidResponse", message: "服务端返回的操作结果不完整或无效。操作可能已经保存，请刷新地图确认后再操作。")
    }
}

private struct OwnerBody: Encodable {
    let owner: String; let loginCode: String
    init(_ session: MapSession) { owner = session.userName; loginCode = session.loginCode }
}
private struct LineAccessBody: Encodable {
    let lineCode: String; let owner: String; let loginCode: String
    init(lineCode: String, session: MapSession) {
        self.lineCode = lineCode; owner = session.userName; loginCode = session.loginCode
    }
}
private struct LineVersionBody: Encodable {
    let lineCode: String; let owner: String; let version: Int64; let loginCode: String
    init(lineCode: String, version: Int64, session: MapSession) {
        self.lineCode = lineCode; self.version = version; owner = session.userName; loginCode = session.loginCode
    }
}
private struct SaveLineBody: Encodable {
    let lineCode: String; let owner: String; let version: Int64; let nodes: [MapLinePoint]; let loginCode: String
}
private struct FindNodeBody: Encodable {
    let lineCode: String; let owner: String; let version: Int64; let nodes: [MapLinePoint]
    let nodeOrder: Int; let targetX: Double; let targetY: Double; let loginCode: String
}
private struct LinePropertiesBody: Encodable {
    let lineCode: String; let owner: String; let version: Int64; let properties: MapLineProperties; let loginCode: String
}
private struct SplitLineBody: Encodable {
    let lineCode: String; let owner: String; let version: Int64; let cutBeforeOrder: Int; let loginCode: String
}
private struct MergeLinesBody: Encodable {
    let firstCode: String; let firstVersion: Int64; let secondCode: String; let secondVersion: Int64
    let owner: String; let loginCode: String
}
private struct ApplyMergeBody: Encodable {
    let firstCode: String; let firstVersion: Int64; let secondCode: String; let secondVersion: Int64
    let owner: String; let firstX: Int; let firstY: Int; let secondX: Int; let secondY: Int; let loginCode: String
}
private struct PasteLineBody: Encodable {
    let owner: String; let source: MapLineCopyData; let x: Int; let y: Int; let loginCode: String
}
private struct CrossEditBody: Encodable {
    let cross: MapCrossKey; let owner: String; let version: Int64; let state: Int; let loginCode: String
}
private struct CreateNodeBody: Encodable {
    let owner: String; let x: Double; let y: Double; let sideLength: Int; let properties: MapNodeProperties
    let loginCode: String; let instanceParentCode: String?
}
private struct UpdateNodeBody: Encodable {
    let code: String; let owner: String; let version: Int64; let value: String; let info: String
    let loginCode: String; let logicLanguage: String; let operandKind: String
}
private struct MoveNodeBody: Encodable {
    let code: String; let owner: String; let version: Int64; let x: Double; let y: Double; let loginCode: String
}
private struct DeleteNodeBody: Encodable {
    let code: String; let owner: String; let version: Int64; let loginCode: String
}
private struct CalculateNodesBody: Encodable {
    let userName: String; let loginCode: String; let incremental: Bool; let afterCode: String?
}
private struct PreviewConnectionBody: Encodable {
    let owner: String; let source: MapLogicalNodeConnectionAnchor; let target: MapLogicalNodeConnectionAnchor
    let loginCode: String; let kind: MapLogicalNodeConnectionKind
}
private struct SaveConnectionBody: Encodable {
    let owner: String; let plan: MapLogicalNodeConnectionPlan; let loginCode: String
}
private struct SelectAreaBody: Encodable {
    let owner: String; let bounds: MapAreaBounds; let loginCode: String
}
private struct TransformAreaBody: Encodable {
    let owner: String; let selection: MapAreaSelection; let deltaX: Int; let deltaY: Int; let loginCode: String
}
private struct DeleteAreaBody: Encodable {
    let owner: String; let selection: MapAreaSelection; let loginCode: String
}
private struct FlowBody: Encodable {
    let owner: String; let text: String; let x: Double; let y: Double; let loginCode: String
}
private struct UndoBody: Encodable {
    let userName: String; let loginCode: String; let requestId: String
}
