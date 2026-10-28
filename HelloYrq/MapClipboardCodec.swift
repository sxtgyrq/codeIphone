import Foundation
import CoreFoundation

enum MapClipboard {
    case line(MapLineCopyData)
    case node(MapLogicalNode)
    case area(MapAreaSelection)
}

struct MapClipboardError: LocalizedError {
    let errorDescription: String? = "剪贴板不是有效的 ArgumentMap 线路、LN 或区域副本，或副本超过容量限制。请重新复制；不支持 LN18、非整数 Cross 或未知格式版本。"
}

/// WPF uses PascalCase for roads, a flat camelCase LN envelope, and camelCase
/// area snapshots. All are ordinary system clipboard strings, not custom UTTypes.
enum MapClipboardCodec {
    static let maximumRoadLength = 8_388_608
    static let maximumAreaLength = 1_000_000
    static let maximumNodeLength = 32_768

    static func encode(_ copy: MapClipboard) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        let limit: Int
        switch copy {
        case .line(let source):
            try validateLine(source)
            encoder.keyEncodingStrategy = .custom { path in
                let key = path.last!.stringValue
                return ClipboardKey(stringValue: key.prefix(1).uppercased() + String(key.dropFirst()))
            }
            data = try encoder.encode(RoadEnvelope(format: "argumentmap.road/1", source: source))
            limit = maximumRoadLength
        case .node(let node):
            try validateNodeProperties(node.properties, size: node.sideLength, standalone: true)
            let p = node.properties
            data = try encoder.encode(NodeEnvelope(format: node.sideLength == 4 ? "argumentmap.ln4/1" : "argumentmap.ln/1",
                size: node.sideLength == 4 ? nil : node.sideLength, value: p.value, logic: p.logicLanguage,
                info: p.info, operandKind: node.sideLength == 6 ? p.operandKind : nil))
            limit = node.sideLength == 4 ? 8192 : maximumNodeLength
        case .area(let selection):
            try validateArea(selection)
            data = try encoder.encode(AreaEnvelope(format: "argumentmap.area/1", selection: stripped(selection)))
            limit = maximumAreaLength
        }
        guard let text = String(data: data, encoding: .utf8), text.utf16.count <= limit else { throw MapClipboardError() }
        return text
    }

    static func decode(_ text: String) throws -> MapClipboard {
        guard !text.isEmpty, text.utf16.count <= maximumRoadLength else { throw MapClipboardError() }
        let data = Data(text.utf8)
        // JSONDecoder and JSONSerialization silently accept duplicate object keys.
        // Reject them before either decoder can discard a conflicting value.
        var scanner = ClipboardJSONScanner(bytes: Array(data))
        try scanner.validate()
        let root = try object(JSONSerialization.jsonObject(with: data), required: [], optional: ["Format", "Source", "format", "selection", "size", "value", "logic", "info", "operandKind"])
        let decoder = JSONDecoder()
        if root["Format"] as? String == "argumentmap.road/1" {
            _ = try object(root, required: ["Format", "Source"])
            try lineSchema(root["Source"]!, pascal: true, snapshot: false)
            decoder.keyDecodingStrategy = .custom { path in
                let key = path.last!.stringValue
                return ClipboardKey(stringValue: key.prefix(1).lowercased() + String(key.dropFirst()))
            }
            let envelope = try decoder.decode(RoadEnvelope.self, from: data)
            try validateLine(envelope.source)
            return .line(envelope.source)
        }
        guard let format = root["format"] as? String else { throw MapClipboardError() }
        switch format {
        case "argumentmap.ln4/1", "argumentmap.ln/1":
            let legacy = format == "argumentmap.ln4/1"
            guard text.utf16.count <= (legacy ? 8192 : maximumNodeLength) else { throw MapClipboardError() }
            _ = try object(root, required: legacy ? ["format", "value", "logic", "info"] : ["format", "size", "value", "logic", "info"],
                           optional: legacy ? [] : ["operandKind"])
            for key in ["format", "value", "logic", "info"] { try string(root[key]) }
            if !legacy { try number(root["size"]) }
            if let kind = root["operandKind"] { try string(kind) }
            let envelope = try decoder.decode(NodeEnvelope.self, from: data)
            let size = legacy ? 4 : envelope.size ?? -1
            var p = MapNodeProperties(value: envelope.value, info: envelope.info, logicLanguage: envelope.logic,
                                      operandKind: envelope.operandKind ?? "Custom")
            if size == 8 && p.value == "¬" && p.logicLanguage == "¬" { p.logicLanguage = "¬(?)" }
            try validateNodeProperties(p, size: size, standalone: true)
            // The LN clipboard carries only size/properties. This code and position
            // are local placeholders; placement submits a new LN through Server.
            return .node(MapLogicalNode(code: "LOCALCOPY", owner: "", version: 0, x: 250_000.5, y: 250_000.5,
                                        sideLength: size, properties: p))
        case "argumentmap.area/1":
            guard text.utf16.count <= maximumAreaLength else { throw MapClipboardError() }
            _ = try object(root, required: ["format", "selection"])
            try areaSchema(root["selection"]!)
            let envelope = try decoder.decode(AreaEnvelope.self, from: data)
            try validateArea(envelope.selection)
            return .area(stripped(envelope.selection))
        default: throw MapClipboardError()
        }
    }

    private static func validateLine(_ line: MapLineCopyData) throws {
        guard validCode(line.code), line.version >= 0, (2...100_000).contains(line.nodes.count),
              line.properties.roadName.utf16.count <= 15, line.properties.roadDetail.utf16.count <= 127,
              (5...500).contains(line.properties.speed), line.properties.passInDirection == 1,
              (0...1).contains(line.properties.passInOpposeDirection) else { throw MapClipboardError() }
        for (index, point) in line.nodes.enumerated() {
            guard point.lineCode == line.code, point.order == index,
                  (0...500_000).contains(point.x), (0...500_000).contains(point.y) else { throw MapClipboardError() }
        }
    }

    private static func validateNodeProperties(_ p: MapNodeProperties, size: Int, standalone: Bool) throws {
        guard [4, 6, 8, 10, 12].contains(size), p.value.utf16.count <= (size == 10 ? 220 : 32),
              p.logicLanguage.utf16.count <= (size == 10 ? 4096 : 255), p.info.utf16.count <= 255,
              MapNodeEditorRules.singleLine(p.value) == p.value, MapNodeEditorRules.singleLine(p.logicLanguage) == p.logicLanguage,
              size == 6 ? ["Custom", "Class", "Instance"].contains(p.operandKind) : p.operandKind == "Custom" else { throw MapClipboardError() }
        guard standalone else { return }
        switch size {
        case 4: guard ["True", "False"].contains(p.value) else { throw MapClipboardError() }
        case 8:
            guard MapNodeEditorRules.relations.contains(where: { $0.symbol == p.value }),
                  p.logicLanguage == MapNodeEditorRules.relationLogic(p.value) else { throw MapClipboardError() }
        case 10:
            guard MapNodeEditorRules.validInstance(p.value), p.value == MapNodeEditorRules.normalizeInstance(p.value),
                  MapNodeEditorRules.instanceParent(p.value).unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }),
                  p.logicLanguage == MapNodeEditorRules.instanceExpression(p.value) else { throw MapClipboardError() }
        default:
            guard !p.logicLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  size != 6 || p.logicLanguage == MapNodeEditorRules.operandLogic(p.logicLanguage, kind: p.operandKind) else { throw MapClipboardError() }
        }
    }

    private static func validateArea(_ selection: MapAreaSelection) throws {
        let bounds = selection.bounds
        guard bounds.isValid, selection.lines.count <= 256, selection.logicalNodes.count <= 256,
              selection.crosses.count <= 4096, !selection.lines.isEmpty || !selection.logicalNodes.isEmpty,
              selection.lines.reduce(0, { $0 + $1.nodes.count }) <= 4096,
              Set(selection.lines.map(\.code)).count == selection.lines.count,
              Set(selection.logicalNodes.map(\.code)).count == selection.logicalNodes.count,
              Set(selection.crosses.map(\.key)).count == selection.crosses.count else { throw MapClipboardError() }
        func contains(_ x: Double, _ y: Double) -> Bool { bounds.left <= x && x <= bounds.right && bounds.bottom <= y && y <= bounds.top }
        for line in selection.lines {
            try validateLine(MapLineCopyData(line: line))
            guard line.nodes.allSatisfy({ contains(Double($0.x), Double($0.y)) }) else { throw MapClipboardError() }
        }
        for node in selection.logicalNodes {
            guard validCode(node.code), node.version >= 0, node.isValidGeometry,
                  contains(node.left, node.bottom), contains(node.right, node.top) else { throw MapClipboardError() }
            try validateNodeProperties(node.properties, size: node.sideLength, standalone: false)
        }
        let roads = Set(selection.lines.map(\.code))
        for cross in selection.crosses {
            guard cross.key.isValid, (-1...3).contains(cross.state), cross.version >= 0,
                  cross.roadOrder1 >= 0, cross.roadOrder2 >= 0, cross.roadVersion1 >= 0, cross.roadVersion2 >= 0,
                  cross.percent1.isFinite, cross.percent2.isFinite, (0...1).contains(cross.percent1), (0...1).contains(cross.percent2),
                  roads.contains(cross.key.roadCode1), roads.contains(cross.key.roadCode2), contains(cross.x, cross.y) else { throw MapClipboardError() }
        }
    }

    private static func stripped(_ selection: MapAreaSelection) -> MapAreaSelection {
        MapAreaSelection(bounds: selection.bounds, lines: selection.lines, logicalNodes: selection.logicalNodes.map {
            MapLogicalNode(code: $0.code, owner: $0.owner, version: $0.version, x: $0.x, y: $0.y,
                           sideLength: $0.sideLength, properties: $0.properties, positions: [], canEdit: nil)
        }, crosses: selection.crosses)
    }
    private static func validCode(_ code: String) -> Bool { code.utf8.count == 10 && code.utf8.allSatisfy { (65...90).contains($0) } }

    // Validate unknown fields and scalar types before permissive Codable models
    // apply defaults. WPF's area writer also emits the listed derived properties.
    private static func lineSchema(_ value: Any, pascal: Bool, snapshot: Bool) throws {
        func key(_ name: String) -> String { pascal ? name.prefix(1).uppercased() + String(name.dropFirst()) : name }
        var fields: Set<String> = ["code", "version", "nodes", "properties", "isLocked"]
        if snapshot { fields.insert("owner") }
        let line = try object(value, required: Set(fields.map(key)))
        try string(line[key("code")]); try number(line[key("version")]); try boolean(line[key("isLocked")])
        if snapshot { try string(line[key("owner")]) }
        let nodes = try array(line[key("nodes")], maximum: 100_000)
        for node in nodes {
            let node = try object(node, required: Set(["lineCode", "order", "x", "y"].map(key)))
            try string(node[key("lineCode")])
            for name in ["order", "x", "y"] { try number(node[key(name)]) }
        }
        let properties = try object(line[key("properties")]!, required: Set(["roadName", "roadDetail", "speed", "passInDirection", "passInOpposeDirection"].map(key)))
        try string(properties[key("roadName")]); try string(properties[key("roadDetail")])
        for name in ["speed", "passInDirection", "passInOpposeDirection"] { try number(properties[key(name)]) }
    }

    private static func areaSchema(_ value: Any) throws {
        let area = try object(value, required: ["bounds", "lines", "logicalNodes", "crosses"])
        let bounds = try object(area["bounds"]!, required: ["left", "bottom", "right", "top"])
        for value in bounds.values { try number(value) }
        for line in try array(area["lines"], maximum: 256) { try lineSchema(line, pascal: false, snapshot: true) }
        for node in try array(area["logicalNodes"], maximum: 256) {
            let node = try object(node, required: ["code", "owner", "version", "x", "y", "sideLength", "properties"],
                                  optional: ["positions", "canEdit", "isStart", "left", "bottom", "right", "top"])
            try string(node["code"]); try string(node["owner"])
            for key in ["version", "x", "y", "sideLength"] { try number(node[key]) }
            for key in ["left", "bottom", "right", "top"] { if let value = node[key] { try number(value) } }
            if let value = node["isStart"] { try boolean(value) }
            if let value = node["canEdit"], !(value is NSNull) { try boolean(value) }
            if let positions = node["positions"] { _ = try array(positions, maximum: 0) }
            let properties = try object(node["properties"]!, required: ["value", "logicLanguage", "info"], optional: ["operandKind"])
            for value in properties.values { try string(value) }
        }
        for cross in try array(area["crosses"], maximum: 4096) {
            let cross = try object(cross, required: ["key", "roadOrder1", "roadOrder2", "roadVersion1", "roadVersion2", "state", "version"],
                                   optional: ["percent1", "percent2", "canTransfer", "stateLabel"])
            for key in ["roadOrder1", "roadOrder2", "roadVersion1", "roadVersion2", "state", "version"] { try number(cross[key]) }
            for key in ["percent1", "percent2"] { if let value = cross[key] { try number(value) } }
            if let value = cross["canTransfer"] { try boolean(value) }
            if let value = cross["stateLabel"] { try string(value) }
            let key = try object(cross["key"]!, required: ["roadCode1", "roadCode2", "position"], optional: ["isValid"])
            try string(key["roadCode1"]); try string(key["roadCode2"])
            if let value = key["isValid"] { try boolean(value) }
            let position = try object(key["position"]!, required: ["x2", "y2"], optional: ["x", "y", "isInteger"])
            try number(position["x2"]); try number(position["y2"])
            for name in ["x", "y"] { if let value = position[name] { try number(value) } }
            if let value = position["isInteger"] { try boolean(value) }
        }
    }

    private static func object(_ value: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw MapClipboardError() }
        return object
    }
    private static func array(_ value: Any?, maximum: Int) throws -> [Any] {
        guard let array = value as? [Any], array.count <= maximum else { throw MapClipboardError() }
        return array
    }
    private static func string(_ value: Any?) throws { guard value is String else { throw MapClipboardError() } }
    private static func number(_ value: Any?) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw MapClipboardError() }
    }
    private static func boolean(_ value: Any?) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw MapClipboardError() }
    }
    private struct RoadEnvelope: Codable { let format: String; let source: MapLineCopyData }
    private struct AreaEnvelope: Codable { let format: String; let selection: MapAreaSelection }
    private struct NodeEnvelope: Codable { let format: String; let size: Int?; let value: String; let logic: String; let info: String; let operandKind: String? }
}

private struct ClipboardKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Bounded lexical pass. Foundation performs final JSON syntax decoding; this
/// pass retains every object key so duplicate/escaped aliases cannot be hidden.
private struct ClipboardJSONScanner {
    let bytes: [UInt8]
    private var index = 0
    private var values = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    mutating func validate() throws {
        try value(depth: 0); whitespace()
        guard index == bytes.count else { throw MapClipboardError() }
    }
    private mutating func value(depth: Int) throws {
        whitespace(); values += 1
        guard depth <= 32, values <= 1_200_000, index < bytes.count else { throw MapClipboardError() }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var names: Set<String> = []
            if consume(125) { return }
            while true {
                whitespace(); let key = try readString(key: true)
                guard names.insert(key).inserted else { throw MapClipboardError() }
                whitespace(); guard consume(58) else { throw MapClipboardError() }
                try value(depth: depth + 1); whitespace()
                if consume(125) { return }
                guard consume(44) else { throw MapClipboardError() }
            }
        case 91:
            index += 1; whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1); whitespace()
                if consume(93) { return }
                guard consume(44) else { throw MapClipboardError() }
            }
        case 34: _ = try readString(key: false)
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57:
            repeat { index += 1 } while index < bytes.count &&
                ([45, 43, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index]))
        default: throw MapClipboardError()
        }
    }
    private mutating func readString(key: Bool) throws -> String {
        guard consume(34) else { throw MapClipboardError() }
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                guard !key || index - start <= 1024 else { throw MapClipboardError() }
                if !key { return "" }
                if escaped { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard let key = String(bytes: bytes[(start + 1)..<(index - 1)], encoding: .utf8) else { throw MapClipboardError() }
                return key
            }
            guard byte >= 32 else { throw MapClipboardError() }
            if byte == 92 {
                escaped = true
                guard index < bytes.count else { throw MapClipboardError() }
                index += 1
            }
        }
        throw MapClipboardError()
    }
    private mutating func literal(_ string: String) throws {
        let token = Array(string.utf8)
        guard index + token.count <= bytes.count, Array(bytes[index..<(index + token.count)]) == token else { throw MapClipboardError() }
        index += token.count
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
    }
    private mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
}
