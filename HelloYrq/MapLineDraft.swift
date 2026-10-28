import Foundation
import CoreGraphics

/// Local editing state. The original version stays unchanged until the Server
/// validates and commits the entire draft through CheckShapeIsOKThenSave.
struct MapLineDraft: Equatable {
    let original: MapLine
    var points: [MapLinePoint]
    var addFromStart = false

    init(line: MapLine) {
        original = line
        points = line.nodes.enumerated().map {
            MapLinePoint(lineCode: line.code, order: $0.offset, x: $0.element.x, y: $0.element.y)
        }
    }

    var lineCode: String { original.code }
    var version: Int64 { original.version }
    var additionAnchor: CGPoint? {
        let point = addFromStart ? points.first : points.last
        return point.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
    }
    var validationMessage: String? {
        if points.count < 2 { return "至少添加两个不同节点后才能保存线路。" }
        var used: Set<MapDraftCoordinate> = []
        for (index, point) in points.enumerated() {
            if point.lineCode != lineCode || point.order != index { return "节点顺序无效，请重新打开线路编辑。" }
            if !(0...500_000).contains(point.x) || !(0...500_000).contains(point.y) {
                return "节点坐标必须在 0…500000 范围内。"
            }
            if !used.insert(MapDraftCoordinate(x: point.x, y: point.y)).inserted {
                return "第 \(index + 1) 个节点与已有节点重合。"
            }
            if index > 0 && !Self.isEightDirection(points[index - 1], point) {
                return "第 \(index) 段不符合横、竖或 45° 方向。"
            }
        }
        return nil
    }

    /// Mirrors WPF's nearest integer point on one of eight rays. Clamp the
    /// ray's length, rather than each axis, so diagonals stay valid at borders.
    static func snap(target: CGPoint, from anchor: CGPoint? = nil) -> CGPoint {
        let fallback = anchor.map(roundedPoint) ?? .zero
        guard target.x.isFinite, target.y.isFinite else { return fallback }
        guard let anchor else { return roundedPoint(target) }
        let start = roundedPoint(anchor)
        let directions: [(CGFloat, CGFloat)] = [(1, 0), (1, 1), (0, 1), (-1, 1),
                                                (-1, 0), (-1, -1), (0, -1), (1, -1)]
        var best = start
        var bestDistance = CGFloat.infinity
        for (dx, dy) in directions {
            let projection = ((target.x - start.x) * dx + (target.y - start.y) * dy) / (dx * dx + dy * dy)
            let horizontal = dx == 0 ? 500_000 : dx > 0 ? 500_000 - start.x : start.x
            let vertical = dy == 0 ? 500_000 : dy > 0 ? 500_000 - start.y : start.y
            let length = min(min(horizontal, vertical), max(0, projection.rounded(.toNearestOrAwayFromZero)))
            let candidate = CGPoint(x: start.x + dx * length, y: start.y + dy * length)
            let distance = pow(candidate.x - target.x, 2) + pow(candidate.y - target.y, 2)
            if distance < bestDistance { bestDistance = distance; best = candidate }
        }
        return best
    }

    mutating func addPoint(_ target: CGPoint) throws {
        try Self.checkTarget(target)
        let candidate = Self.snap(target: target, from: additionAnchor)
        let point = makePoint(candidate)
        try checkDuplicate(point)
        if addFromStart { points.insert(point, at: 0) } else { points.append(point) }
        renumber()
    }

    /// Inserts into the chosen segment; the candidate may introduce a bend,
    /// provided both resulting segments still follow the eight directions.
    mutating func insertPoint(_ target: CGPoint, after index: Int) throws {
        guard index >= 0, index + 1 < points.count else { throw MapLineDraftError("请选择一段线路后插入节点。") }
        try Self.checkTarget(target)
        let point = makePoint(Self.roundedPoint(target))
        try checkDuplicate(point)
        guard Self.isEightDirection(points[index], point), Self.isEightDirection(point, points[index + 1]) else {
            throw MapLineDraftError("插入后两侧线段须为横线、竖线或 45° 斜线。请调整落点。")
        }
        points.insert(point, at: index + 1)
        renumber()
    }

    mutating func movePoint(at index: Int, to target: CGPoint) throws {
        try Self.checkTarget(target)
        let rounded = Self.roundedPoint(target)
        try replacePoint(at: index, x: Int(rounded.x), y: Int(rounded.y))
    }

    /// Apply the exact integer proposal returned by FindNodePosition.
    mutating func replacePoint(at index: Int, x: Int, y: Int) throws {
        guard points.indices.contains(index) else { throw MapLineDraftError("请选择要移动的线路节点。") }
        guard (0...500_000).contains(x), (0...500_000).contains(y) else {
            throw MapLineDraftError("节点坐标必须在 0…500000 范围内。")
        }
        let point = MapLinePoint(lineCode: lineCode, order: index, x: x, y: y)
        try checkDuplicate(point, excluding: index)
        guard (index == 0 || Self.isEightDirection(points[index - 1], point)),
              (index + 1 == points.count || Self.isEightDirection(point, points[index + 1])) else {
            throw MapLineDraftError("移动后两侧线段须为横线、竖线或 45° 斜线。请使用地图上的合法落点建议。")
        }
        points[index] = point
        renumber()
    }

    mutating func removePoint(at index: Int) throws {
        guard points.indices.contains(index) else { throw MapLineDraftError("请选择要删除的线路节点。") }
        if index > 0, index + 1 < points.count,
           !Self.isEightDirection(points[index - 1], points[index + 1]) {
            throw MapLineDraftError("删除后两侧节点无法按八方向连接，请先调整相邻节点。")
        }
        points.remove(at: index)
        renumber()
    }

    mutating func reverse() {
        points.reverse()
        renumber()
    }

    private mutating func renumber() {
        points = points.enumerated().map {
            MapLinePoint(lineCode: lineCode, order: $0.offset, x: $0.element.x, y: $0.element.y)
        }
    }
    private func makePoint(_ point: CGPoint) -> MapLinePoint {
        MapLinePoint(lineCode: lineCode, order: 0, x: Int(point.x), y: Int(point.y))
    }
    private func checkDuplicate(_ point: MapLinePoint, excluding index: Int? = nil) throws {
        if points.enumerated().contains(where: { $0.offset != index && $0.element.x == point.x && $0.element.y == point.y }) {
            throw MapLineDraftError("落点与已有节点重合，请移动到另一个位置。")
        }
    }
    private static func isEightDirection(_ a: MapLinePoint, _ b: MapLinePoint) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx != 0 || dy != 0) && (dx == 0 || dy == 0 || abs(dx) == abs(dy))
    }
    private static func checkTarget(_ point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x <= 500_000, point.y <= 500_000 else {
            throw MapLineDraftError("请选择 0…500000 范围内的坐标。")
        }
    }
    private static func roundedPoint(_ point: CGPoint) -> CGPoint {
        func coordinate(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 0 }
            return min(500_000, max(0, value.rounded(.toNearestOrAwayFromZero)))
        }
        return CGPoint(x: coordinate(point.x), y: coordinate(point.y))
    }
}

struct MapLineDraftError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct MapDraftCoordinate: Hashable {
    let x: Int
    let y: Int
}
