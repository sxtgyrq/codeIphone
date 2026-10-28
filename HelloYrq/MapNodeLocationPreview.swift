import SwiftUI
import Foundation

struct MapNodePreviewLocation: Identifiable, Equatable {
    let code: String
    let x: Double
    let y: Double
    var id: String { code }
    var point: CGPoint { CGPoint(x: x, y: y) }

    init(code: String, x: Double, y: Double) {
        self.code = code; self.x = x; self.y = y
    }

    init(node: MapLogicalNode) {
        self.init(code: node.code, x: node.x, y: node.y)
    }
}

/// The current Server returns a message rather than structured conflict data.
/// Match only WPF's terminal location suffix and only its two duplicate codes.
/// A message never becomes a URL, command, markup, or a write request.
enum MapNodeConflictLocation {
    private static let suffix = try? NSRegularExpression(
        pattern: #"已被 LN ([A-Z]{10})（中心坐标 X=([0-9]+(?:\.[0-9]+)?), Y=([0-9]+(?:\.[0-9]+)?)）使用，请使用不同的(?:值|逻辑语言)。\z"#)

    static func parse(_ error: Error) -> MapNodePreviewLocation? {
        guard let error = error as? MapAPIError,
              ["DuplicateLogicalNodeValue", "DuplicateLogicalNodeLogic"].contains(error.code),
              let suffix,
              let match = suffix.firstMatch(in: error.message, range: NSRange(error.message.startIndex..., in: error.message)),
              let codeRange = Range(match.range(at: 1), in: error.message),
              let xRange = Range(match.range(at: 2), in: error.message),
              let yRange = Range(match.range(at: 3), in: error.message),
              let x = coordinate(String(error.message[xRange])),
              let y = coordinate(String(error.message[yRange])) else { return nil }
        return MapNodePreviewLocation(code: String(error.message[codeRange]), x: x, y: y)
    }

    private static func coordinate(_ text: String) -> Double? {
        // Compare the exact decimal spelling to the bound before Double can
        // round an out-of-range fraction back down to 500000.
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts[0].drop(while: { $0 == "0" })
        guard integer.count <= 6, let whole = Int(integer.isEmpty ? "0" : String(integer)), whole <= 500_000,
              whole < 500_000 || parts.count == 1 || parts[1].allSatisfy({ $0 == "0" }),
              let value = Double(text), value.isFinite, (0...500_000).contains(value) else { return nil }
        return value
    }
}

/// A nested sheet keeps the editor and its unsaved @State alive. The preview
/// receives only a value snapshot, with no API, view model, or write callbacks.
@MainActor
struct MapNodeLocationPreview: View {
    let snapshot: MapSnapshot
    let location: MapNodePreviewLocation
    @StateObject private var interaction: MapInteraction
    @State private var fitRequest = 0
    @Environment(\.dismiss) private var dismiss

    init(snapshot: MapSnapshot, location: MapNodePreviewLocation) {
        self.snapshot = snapshot; self.location = location
        let interaction = MapInteraction()
        interaction.setViewport(MapViewport(center: location.point, scale: 12))
        interaction.selectedID = "ln:\(location.code)"
        self._interaction = StateObject(wrappedValue: interaction)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(location.code).font(.headline.monospaced())
                    Text("X \(coordinate(location.x)) · Y \(coordinate(location.y))")
                        .font(.subheadline).accessibilityIdentifier("previewNodeCoordinates")
                    Text("只读预览，可拖动或缩放。返回后继续编辑，未保存内容会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !snapshot.logicalNodes.contains(where: { $0.code == location.code && $0.x == location.x && $0.y == location.y }) {
                        Text("当前快照未包含此位置的 LN；标记显示服务器返回的位置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                ZStack {
                    MapCanvasView(interaction: interaction, snapshot: snapshot, showArrows: true,
                                  showLabels: true, showCrosses: true, fitRequest: fitRequest, onSelect: { _ in })
                    GeometryReader { geometry in
                        let transform = MapTransform(center: interaction.cursor, scale: interaction.currentScale, size: geometry.size)
                        Image(systemName: "scope")
                            .font(.system(size: 30, weight: .semibold)).foregroundStyle(.orange)
                            .shadow(color: Color(uiColor: .systemBackground), radius: 2)
                            .position(transform.screen(location.point))
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }.clipped()
                HStack {
                    Button { interaction.locate(location.point, scale: 12) } label: {
                        Label("回到此 LN", systemImage: "scope").frame(minHeight: 44)
                    }.accessibilityIdentifier("previewLocateNode")
                    Spacer()
                    Button { fitRequest += 1 } label: {
                        Label("查看全图", systemImage: "arrow.up.left.and.arrow.down.right").frame(minHeight: 44)
                    }.disabled(snapshot.isEmpty).accessibilityIdentifier("previewFitMap")
                }.padding(.horizontal)
            }
            .navigationTitle("LN 位置预览").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("返回编辑") { dismiss() }.frame(minHeight: 44).accessibilityIdentifier("returnToNodeEditor")
                }
            }
        }
    }

    private func coordinate(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
