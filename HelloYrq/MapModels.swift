import Foundation

struct MapSession: Codable, Hashable, Sendable {
    let userName: String
    let loginCode: String
}

struct MapLinePoint: Codable, Hashable, Identifiable, Sendable {
    let lineCode: String
    let order: Int
    let x: Int
    let y: Int

    var id: String { "\(lineCode):\(order)" }
}

struct MapLineProperties: Codable, Hashable, Sendable {
    var roadName = ""
    var roadDetail = ""
    var speed = 100
    var passInDirection = 1
    var passInOpposeDirection = 0
}

extension MapLineProperties {
    private enum CodingKeys: String, CodingKey {
        case roadName, roadDetail, speed, passInDirection, passInOpposeDirection
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            roadName: try values.decodeIfPresent(String.self, forKey: .roadName) ?? "",
            roadDetail: try values.decodeIfPresent(String.self, forKey: .roadDetail) ?? "",
            speed: try values.decodeIfPresent(Int.self, forKey: .speed) ?? 100,
            passInDirection: try values.decodeIfPresent(Int.self, forKey: .passInDirection) ?? 1,
            passInOpposeDirection: try values.decodeIfPresent(Int.self, forKey: .passInOpposeDirection) ?? 0
        )
    }
}

struct MapLine: Codable, Hashable, Identifiable, Sendable {
    let code: String
    let owner: String
    let isLocked: Bool
    let version: Int64
    let nodes: [MapLinePoint]
    var properties = MapLineProperties()

    var id: String { code }
}

extension MapLine {
    private enum CodingKeys: String, CodingKey {
        case code, owner, isLocked, version, nodes, properties
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            code: try values.decode(String.self, forKey: .code),
            owner: try values.decode(String.self, forKey: .owner),
            isLocked: try values.decode(Bool.self, forKey: .isLocked),
            version: try values.decode(Int64.self, forKey: .version),
            nodes: try values.decode([MapLinePoint].self, forKey: .nodes),
            properties: try values.decodeIfPresent(MapLineProperties.self, forKey: .properties) ?? MapLineProperties()
        )
    }
}

struct MapNodeProperties: Codable, Hashable, Sendable {
    var value = "逻辑节点"
    var info = ""
    var logicLanguage = ""
    var operandKind = "Custom"
}

extension MapNodeProperties {
    private enum CodingKeys: String, CodingKey {
        case value, info, logicLanguage, operandKind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try values.decodeIfPresent(String.self, forKey: .value) ?? "逻辑节点",
            info: try values.decodeIfPresent(String.self, forKey: .info) ?? "",
            logicLanguage: try values.decodeIfPresent(String.self, forKey: .logicLanguage) ?? "",
            operandKind: try values.decodeIfPresent(String.self, forKey: .operandKind) ?? "Custom"
        )
    }
}

struct MapNodePosition: Codable, Hashable, Identifiable, Sendable {
    let logicalNodeCode: String
    let roadCode: String
    let roadOrder: Int
    let roadPercent: Double
    let x: Double
    let y: Double
    let roadVersion: Int64
    var isChanged = false

    var id: String { "\(logicalNodeCode):\(roadCode):\(roadOrder)" }
}

extension MapNodePosition {
    private enum CodingKeys: String, CodingKey {
        case logicalNodeCode, roadCode, roadOrder, roadPercent, x, y, roadVersion, isChanged
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            logicalNodeCode: try values.decode(String.self, forKey: .logicalNodeCode),
            roadCode: try values.decode(String.self, forKey: .roadCode),
            roadOrder: try values.decode(Int.self, forKey: .roadOrder),
            roadPercent: try values.decode(Double.self, forKey: .roadPercent),
            x: try values.decode(Double.self, forKey: .x),
            y: try values.decode(Double.self, forKey: .y),
            roadVersion: try values.decode(Int64.self, forKey: .roadVersion),
            isChanged: try values.decodeIfPresent(Bool.self, forKey: .isChanged) ?? false
        )
    }
}

struct MapLogicalNode: Codable, Hashable, Identifiable, Sendable {
    let code: String
    let owner: String
    let version: Int64
    let x: Double
    let y: Double
    let sideLength: Int
    var properties = MapNodeProperties()
    var positions: [MapNodePosition] = []
    var canEdit: Bool? = nil

    var id: String { code }
    var isStart: Bool { sideLength == 18 }
    var left: Double { x - Double(sideLength) / 2 }
    var right: Double { x + Double(sideLength) / 2 }
    var bottom: Double { y - Double(sideLength) / 2 }
    var top: Double { y + Double(sideLength) / 2 }
}

extension MapLogicalNode {
    private enum CodingKeys: String, CodingKey {
        case code, owner, version, x, y, sideLength, properties, positions, canEdit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            code: try values.decode(String.self, forKey: .code),
            owner: try values.decode(String.self, forKey: .owner),
            version: try values.decode(Int64.self, forKey: .version),
            x: try values.decode(Double.self, forKey: .x),
            y: try values.decode(Double.self, forKey: .y),
            sideLength: try values.decode(Int.self, forKey: .sideLength),
            properties: try values.decodeIfPresent(MapNodeProperties.self, forKey: .properties) ?? MapNodeProperties(),
            positions: try values.decodeIfPresent([MapNodePosition].self, forKey: .positions) ?? [],
            canEdit: try values.decodeIfPresent(Bool.self, forKey: .canEdit)
        )
    }
}

struct MapCrossPosition: Codable, Hashable, Sendable {
    let x2: Int
    let y2: Int

    var x: Double { Double(x2) / 2 }
    var y: Double { Double(y2) / 2 }
    var isInteger: Bool { x2.isMultiple(of: 2) && y2.isMultiple(of: 2) }
    var isValid: Bool {
        isInteger && (0...1_000_000).contains(x2) && (0...1_000_000).contains(y2)
    }
}

extension MapCrossPosition {
    private enum CodingKeys: String, CodingKey { case x2, y2 }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x2: try values.decode(Int.self, forKey: .x2), y2: try values.decode(Int.self, forKey: .y2))
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .x2, in: values,
                debugDescription: "Cross 必须为范围内的整数坐标，x2 和 y2 必须为偶数。")
        }
    }
}

struct MapCrossKey: Codable, Hashable, Sendable {
    let roadCode1: String
    let roadCode2: String
    let position: MapCrossPosition

    var isValid: Bool {
        func validCode(_ code: String) -> Bool {
            code.utf8.count == 10 && code.utf8.allSatisfy { (65...90).contains($0) }
        }
        return validCode(roadCode1) && validCode(roadCode2) && roadCode1 > roadCode2 && position.isValid
    }
}

extension MapCrossKey {
    private enum CodingKeys: String, CodingKey { case roadCode1, roadCode2, position }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            roadCode1: try values.decode(String.self, forKey: .roadCode1),
            roadCode2: try values.decode(String.self, forKey: .roadCode2),
            position: try values.decode(MapCrossPosition.self, forKey: .position)
        )
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .roadCode1, in: values,
                debugDescription: "Cross 需要两个不同的十位大写线路编码，且 roadCode1 必须大于 roadCode2。")
        }
    }
}

struct MapCross: Codable, Hashable, Identifiable, Sendable {
    let key: MapCrossKey
    let roadOrder1: Int
    let roadOrder2: Int
    let roadVersion1: Int64
    let roadVersion2: Int64
    let state: Int
    let version: Int64
    var percent1: Double = 0
    var percent2: Double = 0

    var id: MapCrossKey { key }
    var x: Double { key.position.x }
    var y: Double { key.position.y }
    var canTransfer: Bool { [1, 2, 3].contains(state) }
    var stateLabel: String {
        switch state {
        case -1: return "不连通"
        case 0: return "未设置"
        case 1: return "双向连通"
        case 2: return "\(key.roadCode1) → \(key.roadCode2)"
        case 3: return "\(key.roadCode2) → \(key.roadCode1)"
        default: return "未知状态"
        }
    }
}

extension MapCross {
    private enum CodingKeys: String, CodingKey {
        case key, roadOrder1, roadOrder2, roadVersion1, roadVersion2, state, version, percent1, percent2
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try values.decode(MapCrossKey.self, forKey: .key),
            roadOrder1: try values.decode(Int.self, forKey: .roadOrder1),
            roadOrder2: try values.decode(Int.self, forKey: .roadOrder2),
            roadVersion1: try values.decode(Int64.self, forKey: .roadVersion1),
            roadVersion2: try values.decode(Int64.self, forKey: .roadVersion2),
            state: try values.decode(Int.self, forKey: .state),
            version: try values.decode(Int64.self, forKey: .version),
            percent1: try values.decodeIfPresent(Double.self, forKey: .percent1) ?? 0,
            percent2: try values.decodeIfPresent(Double.self, forKey: .percent2) ?? 0
        )
        guard (-1...3).contains(state), roadOrder1 >= 0, roadOrder2 >= 0,
              roadVersion1 >= 0, roadVersion2 >= 0, version >= 0,
              percent1.isFinite, percent2.isFinite,
              (0...1).contains(percent1), (0...1).contains(percent2) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: values,
                debugDescription: "Cross 的状态、版本或线路位置无效。")
        }
    }
}

struct MapSnapshot: Codable, Hashable, Sendable {
    var lines: [MapLine] = []
    var logicalNodes: [MapLogicalNode] = []
    var crosses: [MapCross] = []

    static let empty = MapSnapshot()
    var isEmpty: Bool { lines.isEmpty && logicalNodes.isEmpty && crosses.isEmpty }
}
