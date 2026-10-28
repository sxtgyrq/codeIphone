import SwiftUI

enum MapTool: String, CaseIterable, Identifiable {
    case browse = "浏览", line = "线路", cross = "Cross", node = "LN", area = "区域"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .browse: return "hand.draw"
        case .line: return "point.topleft.down.to.point.bottomright.curvepath"
        case .cross: return "arrow.triangle.branch"
        case .node: return "square.on.square"
        case .area: return "rectangle.dashed"
        }
    }
}

struct MapFocusRequest {
    let id = UUID()
    let point: CGPoint
    var scale: CGFloat? = nil
}

/// Pure fit calculation, shared by the first rendered frame and persisted
/// document viewport. Missing data/layout leaves initialization pending.
struct MapViewport: Hashable {
    let center: CGPoint
    let scale: CGFloat

    func hash(into hasher: inout Hasher) {
        hasher.combine(center.x)
        hasher.combine(center.y)
        hasher.combine(scale)
    }

    static func fitted(snapshot: MapSnapshot, size: CGSize,
                       continuation: [MapLogicalNodeContinuationPoint] = []) -> MapViewport? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func include(_ point: CGPoint) {
            guard point.x.isFinite, point.y.isFinite else { return }
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        for line in snapshot.lines {
            for point in line.nodes { include(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
        }
        for node in snapshot.logicalNodes where node.x.isFinite && node.y.isFinite {
            let half = CGFloat(node.sideLength) / 2
            include(CGPoint(x: CGFloat(node.x) - half, y: CGFloat(node.y) - half))
            include(CGPoint(x: CGFloat(node.x) + half, y: CGFloat(node.y) + half))
        }
        for cross in snapshot.crosses {
            let point = cross.key.position
            guard (0...1_000_000).contains(point.x2), (0...1_000_000).contains(point.y2),
                  point.x2 % 2 == 0, point.y2 % 2 == 0, (-1...3).contains(cross.state) else { continue }
            include(CGPoint(x: CGFloat(cross.x), y: CGFloat(cross.y)))
        }
        for point in continuation { include(CGPoint(x: point.x, y: point.y)) }
        guard minX.isFinite, minY.isFinite else { return nil }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let center = CGPoint(x: min(500_000, max(0, bounds.midX)), y: min(500_000, max(0, bounds.midY)))
        let scale = min(32, max(0.0001, min(max(1, size.width - 96) / max(20, bounds.width),
                                          max(1, size.height - 120) / max(20, bounds.height))))
        return MapViewport(center: center, scale: scale)
    }
}

@MainActor
final class MapInteraction: ObservableObject {
    @Published var tool: MapTool = .browse
    @Published var cursor = CGPoint(x: 250_000, y: 250_000)
    @Published var focus: MapFocusRequest?
    @Published var showCursor = false
    @Published var selectedID: String?
    @Published var draftPoints: [MapLinePoint] = []
    @Published var draftAnchor: CGPoint?
    @Published var selectedPoint: Int?
    @Published var hiddenLineCode: String?
    @Published var preview: MapSnapshot?
    @Published var continuation: [MapLogicalNodeContinuationPoint] = []
    @Published var currentScale: CGFloat = 1
    @Published var hasFittedViewport = false
    @Published var region: MapAreaBounds?
    @Published var showProtection = false
    @Published var showSpeeds = false
    @Published var connected = true
    @Published var disconnected = true
    @Published var unset = true
    @Published var zoomRequest = 0

    @discardableResult
    func initializeViewport(_ viewport: MapViewport?) -> Bool {
        guard !hasFittedViewport, let viewport else { return false }
        setViewport(viewport)
        return true
    }

    func setViewport(_ viewport: MapViewport) {
        cursor = viewport.center
        currentScale = viewport.scale
        hasFittedViewport = true
    }

    func locate(_ point: CGPoint, scale: CGFloat? = nil) {
        focus = MapFocusRequest(point: point, scale: scale)
    }
    func includes(_ cross: MapCross) -> Bool {
        cross.state == -1 ? disconnected : cross.state == 0 ? unset : connected
    }
    func clearPreview() {
        showCursor = false; draftPoints = []; draftAnchor = nil; selectedPoint = nil
        hiddenLineCode = nil; preview = nil; continuation = []; region = nil
    }
}

enum AppRelease {
    static var date: String {
        Bundle.main.object(forInfoDictionaryKey: "ArgumentMapReleaseDate") as? String ?? "2026.10.29"
    }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var title: String { "版本 \(date)" }
}
