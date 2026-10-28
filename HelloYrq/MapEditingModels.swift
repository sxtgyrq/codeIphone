import Foundation

// These DTOs mirror ArgumentMap.Contracts. Existing object snapshots are sent
// back unchanged as optimistic concurrency tokens; the Server remains authoritative.
struct MapNodePositionProposal: Codable, Hashable, Sendable {
    let nodeOrder: Int
    let x: Int
    let y: Int
}

struct MapLineCopyData: Codable, Hashable, Sendable {
    let code: String
    let version: Int64
    let nodes: [MapLinePoint]
    let properties: MapLineProperties
    let isLocked: Bool

    init(line: MapLine) {
        code = line.code; version = line.version; nodes = line.nodes
        properties = line.properties; isLocked = line.isLocked
    }
}

struct MapLinePasteResult: Codable, Hashable, Sendable {
    let line: MapLine
    let map: MapSnapshot
}

struct MapMergePlan: Codable, Hashable, Identifiable, Sendable {
    let firstX: Int
    let firstY: Int
    let secondX: Int
    let secondY: Int
    let directionX: Int
    let directionY: Int
    let firstCorner: Int
    let secondCorner: Int
    let adjustedGridSteps: Int

    var id: String { "\(firstX):\(firstY):\(secondX):\(secondY)" }
}

struct MapMergePreview: Codable, Hashable, Sendable {
    let first: MapLine
    let second: MapLine
    let plans: [MapMergePlan]
}

struct MapLineTopologyResult: Codable, Hashable, Sendable {
    let lines: [MapLine]
    let removedCodes: [String]
    let adjustedGridSteps: Int
}

struct MapCrossCalculationProgress: Codable, Hashable, Sendable {
    let canContinue: Bool
    let remainingSegments: Int
    let crossCount: Int
}

struct MapLogicalNodeCalculationProgress: Codable, Hashable, Sendable {
    let canContinue: Bool
    let remainingNodes: Int
    let nodeCount: Int
    let nextCode: String?
}

enum MapLogicalNodeConnectionKind: Int, Codable, CaseIterable, Identifiable, Sendable {
    case direct = 0, goTo = 1, find = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .direct: return "直连"
        case .goTo: return "前往"
        case .find: return "寻找"
        }
    }
}

struct MapLogicalNodeConnectionAnchor: Codable, Hashable, Sendable {
    let code: String
    let x: Double
    let y: Double
    let sideLength: Int

    init(node: MapLogicalNode) {
        code = node.code; x = node.x; y = node.y; sideLength = node.sideLength
    }
}

struct MapLogicalNodeConnectionJoin: Codable, Hashable, Sendable {
    let roadCode: String
    let position: MapCrossPosition
}

struct MapLogicalNodeContinuationPoint: Codable, Hashable, Sendable {
    let roadCode: String
    let x: Double
    let y: Double
}

struct MapLogicalNodeConnectionPlan: Codable, Hashable, Sendable {
    let source: MapLogicalNodeConnectionAnchor
    let target: MapLogicalNodeConnectionAnchor
    let lineCode: String
    let nodes: [MapLinePoint]
    let kind: MapLogicalNodeConnectionKind
    let join: MapLogicalNodeConnectionJoin?
    let continuation: [MapLogicalNodeContinuationPoint]
}

struct MapLogicalNodeConnectionResult: Codable, Hashable, Sendable {
    let line: MapLine
    let map: MapSnapshot
    let disconnectedCrosses: Int
}

struct MapAreaBounds: Codable, Hashable, Sendable {
    let left: Double
    let bottom: Double
    let right: Double
    let top: Double

    var isValid: Bool {
        [left, bottom, right, top].allSatisfy(\.isFinite) &&
            left >= 0 && bottom >= 0 && right <= 500_000 && top <= 500_000 &&
            left < right && bottom < top
    }
}

struct MapAreaSelection: Codable, Hashable, Sendable {
    let bounds: MapAreaBounds
    let lines: [MapLine]
    let logicalNodes: [MapLogicalNode]
    let crosses: [MapCross]

    var snapshot: MapSnapshot { MapSnapshot(lines: lines, logicalNodes: logicalNodes, crosses: crosses) }
}

struct MapAreaPasteResult: Codable, Hashable, Sendable {
    let added: MapSnapshot
    let map: MapSnapshot
    let logicalNodeCodes: [String: String]
    let roadCodes: [String: String]
    let notes: [String]
}

struct MapFlowDiagramResult: Codable, Hashable, Sendable {
    let added: MapSnapshot
    let map: MapSnapshot?
    let logicalNodeCodes: [String: String]
    let roadCodes: [String: String]
    let notes: [String]
}

struct MapUndoResult: Codable, Hashable, Sendable {
    let operation: String
    let map: MapSnapshot
}
