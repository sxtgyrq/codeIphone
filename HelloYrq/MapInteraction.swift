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
        Bundle.main.object(forInfoDictionaryKey: "ArgumentMapReleaseDate") as? String ?? "2026.10.28"
    }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var title: String { "版本 \(date)" }
}
