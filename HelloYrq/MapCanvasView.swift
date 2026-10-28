import SwiftUI
import Foundation

enum MapSelection: Identifiable {
    case line(MapLine)
    case logicalNode(MapLogicalNode)
    case cross(MapCross)

    var id: String {
        switch self {
        case .line(let line): return "line:\(line.code)"
        case .logicalNode(let node): return "ln:\(node.code)"
        case .cross(let cross):
            return "cross:\(cross.key.roadCode1):\(cross.key.roadCode2):\(cross.key.position.x2):\(cross.key.position.y2)"
        }
    }
}

/// Drawing and gestures remain local; only explicit Save/Confirm actions write to Server.
@MainActor
struct MapCanvasView: View {
    @ObservedObject var interaction: MapInteraction
    let snapshot: MapSnapshot
    let showArrows: Bool
    let showLabels: Bool
    let showCrosses: Bool
    let fitRequest: Int
    var onSelect: (MapSelection?) -> Void
    var onPoint: ((CGPoint) -> Void)? = nil

    // The document owns the viewport so refreshing content or changing dock
    // layout never replaces it with the initial fit of a new Canvas value.
    private var center: CGPoint {
        get { interaction.cursor }
        nonmutating set { interaction.cursor = newValue }
    }
    private var scale: CGFloat {
        get { interaction.currentScale }
        nonmutating set { interaction.currentScale = newValue }
    }
    @State private var dragOrigin: CGPoint?
    @State private var pinchScale: CGFloat?
    private var selectedID: String? { interaction.selectedID }

    var body: some View {
        GeometryReader { geometry in
            // Login can mount an empty canvas before the first snapshot arrives.
            // Derive the first frame from the current snapshot/layout, rather
            // than depending on an appearance callback that captured empty data.
            let initialViewport = interaction.hasFittedViewport ? nil :
                MapViewport.fitted(snapshot: snapshot, size: geometry.size, continuation: interaction.continuation)
            let viewport = initialViewport ?? MapViewport(center: center, scale: scale)
            let transform = MapTransform(center: viewport.center, scale: viewport.scale, size: geometry.size)
            ZStack(alignment: .bottom) {
                Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                    var drawingContext = context
                    drawMap(context: &drawingContext, transform: transform, size: size)
                }
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .simultaneousGesture(SpatialTapGesture().onEnded { event in
                    if interaction.showCursor {
                        let point = transform.world(event.location)
                        center = bounded(point)
                        interaction.cursor = center
                        onPoint?(center)
                        return
                    }
                    let selection = hitTest(event.location, transform: transform)
                    onSelect(selection)
                })
                .accessibilityLabel("逻辑地图，\(snapshot.lines.count) 条线路，\(snapshot.logicalNodes.count) 个逻辑节点")
                .accessibilityHint("单指拖动平移，双指捏合缩放，轻点对象查看资料。")
                .accessibilityIdentifier("logicMap")
                .accessibilityAction(named: Text("查看全部")) { fit(in: geometry.size) }

                scaleOverlay(transform: transform)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .clipped()
            .task(id: initialViewport) { @MainActor in
                // Let layout finish before publishing document state. A newer
                // snapshot/size cancels this task and supplies its own fit.
                await Task.yield()
                guard !Task.isCancelled else { return }
                interaction.initializeViewport(initialViewport)
            }
            .onChange(of: fitRequest) { _ in fit(in: geometry.size) }
            .onChange(of: interaction.focus?.id) { _ in
                guard let request = interaction.focus else { return }
                center = bounded(request.point)
                if let requestedScale = request.scale { scale = min(MapTransform.maximumScale, max(0.0001, requestedScale)) }
                interaction.hasFittedViewport = true
            }
            .onChange(of: interaction.zoomRequest) { value in
                guard value != 0 else { return }
                scale = min(MapTransform.maximumScale, max(0.0001, scale * (value > 0 ? 1.6 : 0.625)))
                interaction.hasFittedViewport = true
            }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard pinchScale == nil else { return }
                if dragOrigin == nil { dragOrigin = center }
                guard let start = dragOrigin else { return }
                center = bounded(CGPoint(x: start.x - value.translation.width / scale,
                                         y: start.y + value.translation.height / scale))
                interaction.hasFittedViewport = true
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchScale == nil { pinchScale = scale; dragOrigin = nil }
                guard let initial = pinchScale, value.isFinite, value > 0 else { return }
                scale = min(MapTransform.maximumScale, max(0.0001, initial * value))
                interaction.hasFittedViewport = true
            }
            .onEnded { _ in pinchScale = nil }
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(500_000, max(0, point.x)), y: min(500_000, max(0, point.y)))
    }

    private func fit(in size: CGSize) {
        guard let viewport = MapViewport.fitted(snapshot: snapshot, size: size,
                                                continuation: interaction.continuation) else { return }
        interaction.setViewport(viewport)
        dragOrigin = nil
        pinchScale = nil
    }

    private func drawMap(context: inout GraphicsContext, transform: MapTransform, size: CGSize) {
        let screen = CGRect(origin: .zero, size: size)
        context.fill(Path(screen), with: .color(Color(uiColor: .systemBackground)))
        drawGrid(context: &context, transform: transform)
        for node in snapshot.logicalNodes { drawNode(node, context: &context, transform: transform) }
        for line in snapshot.lines where line.code != interaction.hiddenLineCode { drawLine(line, context: &context, transform: transform) }
        if showCrosses {
            for cross in snapshot.crosses where valid(cross) && interaction.includes(cross) {
                drawCross(cross, context: &context, transform: transform)
            }
        }
        if showLabels {
            var occupied: [CGRect] = []
            // Reserve the selected label first; stable order avoids flicker on refresh.
            let nodes = snapshot.logicalNodes.sorted {
                let firstSelected = selectedID == MapSelection.logicalNode($0).id
                let secondSelected = selectedID == MapSelection.logicalNode($1).id
                return firstSelected == secondSelected ? $0.code < $1.code : firstSelected
            }
            for node in nodes { drawLabel(node, context: &context, transform: transform, occupied: &occupied) }
        }
        drawEditing(context: &context, transform: transform)
    }

    private func drawGrid(context: inout GraphicsContext, transform: MapTransform) {
        let step = transform.gridStep
        let left = max(0, transform.world(.zero).x)
        let right = min(500_000, transform.world(CGPoint(x: transform.size.width, y: 0)).x)
        let top = min(500_000, transform.world(.zero).y)
        let bottom = max(0, transform.world(CGPoint(x: 0, y: transform.size.height)).y)
        guard left <= right, bottom <= top else { return }
        var path = Path()
        var x = ceil(left / step) * step
        while x <= right {
            path.move(to: transform.screen(CGPoint(x: x, y: bottom)))
            path.addLine(to: transform.screen(CGPoint(x: x, y: top)))
            x += step
        }
        var y = ceil(bottom / step) * step
        while y <= top {
            path.move(to: transform.screen(CGPoint(x: left, y: y)))
            path.addLine(to: transform.screen(CGPoint(x: right, y: y)))
            y += step
        }
        context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 0.6)
    }

    private func drawLine(_ line: MapLine, context: inout GraphicsContext, transform: MapTransform) {
        guard line.nodes.count >= 2 else { return }
        let chosen = selectedID == MapSelection.line(line).id
        let color = chosen ? Color.orange : line.isLocked ? Color.green : Color(red: 0.20, green: 0.46, blue: 0.78)
        let clip = CGRect(origin: .zero, size: transform.size).insetBy(dx: -20, dy: -20)
        var path = Path()
        for index in 1..<line.nodes.count {
            let a = line.nodes[index - 1], b = line.nodes[index]
            let start = transform.screen(CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
            let end = transform.screen(CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
            guard segmentBounds(start, end).insetBy(dx: -2, dy: -2).intersects(clip) else { continue }
            path.move(to: start); path.addLine(to: end)
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: chosen ? 3 : 1.5, lineCap: .round, lineJoin: .round))
        guard showArrows else { return }
        for index in 1..<line.nodes.count {
            let a = line.nodes[index - 1], b = line.nodes[index]
            let start = transform.screen(CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
            let end = transform.screen(CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length >= 28, let visible = clippedSegment(start, end, to: clip) else { continue }
            let direction = CGVector(dx: dx / length, dy: dy / length)
            let visibleLength = distance(visible.0, visible.1)
            guard visibleLength >= 28 else { continue }
            let count = min(5, max(1, Int(visibleLength / 120)))
            for index in 0..<count {
                let fraction = CGFloat(index + 1) / CGFloat(count + 1)
                let location = CGPoint(x: visible.0.x + (visible.1.x - visible.0.x) * fraction,
                                       y: visible.0.y + (visible.1.y - visible.0.y) * fraction)
                guard clip.contains(location) else { continue }
                if interaction.showSpeeds && index == 0 {
                    context.draw(Text("\(line.properties.speed)").font(.system(size: 10)).foregroundColor(color),
                                 at: CGPoint(x: location.x + 10, y: location.y - 12))
                }
                if line.properties.passInOpposeDirection == 1 {
                    drawArrow(at: CGPoint(x: location.x - direction.dy * 3, y: location.y + direction.dx * 3), direction: direction, color: color, context: &context)
                    drawArrow(at: CGPoint(x: location.x + direction.dy * 3, y: location.y - direction.dx * 3), direction: CGVector(dx: -direction.dx, dy: -direction.dy), color: color, context: &context)
                } else if line.properties.passInDirection == 1 {
                    drawArrow(at: location, direction: direction, color: color, context: &context)
                }
            }
        }
    }

    private func drawArrow(at point: CGPoint, direction: CGVector, color: Color, context: inout GraphicsContext) {
        var arrow = Path()
        arrow.move(to: CGPoint(x: point.x - direction.dx * 5 - direction.dy * 3, y: point.y - direction.dy * 5 + direction.dx * 3))
        arrow.addLine(to: point)
        arrow.addLine(to: CGPoint(x: point.x - direction.dx * 5 + direction.dy * 3, y: point.y - direction.dy * 5 - direction.dx * 3))
        context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawNode(_ node: MapLogicalNode, context: inout GraphicsContext, transform: MapTransform) {
        guard node.x.isFinite, node.y.isFinite else { return }
        let rect = nodeRect(node, transform: transform)
        guard rect.insetBy(dx: -4, dy: -4).intersects(CGRect(origin: .zero, size: transform.size)) else { return }
        let color = nodeColor(node.sideLength)
        if interaction.showProtection {
            let side = CGFloat(node.sideLength * 3 - 1) * transform.scale
            let protection = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            context.stroke(Path(protection), with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3]))
        }
        let path = nodePath(rect: rect, size: node.sideLength, cut: min(rect.width / 2, 0.5 * transform.scale))
        context.fill(path, with: .color(color.opacity(0.09)))
        context.stroke(path, with: .color(color), lineWidth: selectedID == MapSelection.logicalNode(node).id ? 3 : 1.5)
        if rect.width < 3 {
            context.fill(Path(ellipseIn: CGRect(x: rect.midX - 1.5, y: rect.midY - 1.5, width: 3, height: 3)), with: .color(color))
        }
    }

    private func drawLabel(_ node: MapLogicalNode, context: inout GraphicsContext, transform: MapTransform, occupied: inout [CGRect]) {
        guard node.x.isFinite, node.y.isFinite else { return }
        let rect = nodeRect(node, transform: transform)
        let chosen = selectedID == MapSelection.logicalNode(node).id
        guard rect.width >= 4 || chosen else { return }
        let screen = CGRect(origin: .zero, size: transform.size)
        guard rect.insetBy(dx: -12, dy: -12).intersects(screen) else { return }
        // Keep labels clear of the coordinate/scale strip. This affects drawing only.
        let viewport = CGRect(x: 7, y: 7, width: max(0, screen.width - 14), height: max(0, screen.height - 48))
        let overview = transform.scale < 2.5 && !chosen
        let detailed = transform.scale >= 6 || chosen
        let value = node.properties.value.isEmpty ? (node.sideLength == 18 ? "开始" : node.code) : node.properties.value
        let compact = shortened(value, limit: 6)
        var parts = [overview ? compact : shortened(value, limit: detailed ? 36 : 18)]
        if !overview && !node.properties.logicLanguage.isEmpty && node.properties.logicLanguage != node.properties.value {
            parts.append(shortened(node.properties.logicLanguage, limit: detailed ? 160 : 48))
        }
        let text = parts.joined(separator: "\n")
        let variants = text == compact ? [text] : [text, compact]
        for content in variants {
            let label = Text(content)
                .font(.system(size: overview ? 10 : 11))
                .foregroundColor(Color(red: 0.10, green: 0.19, blue: 0.31))
            let resolved = context.resolve(label)
            let width = min(viewport.width - 6, overview ? 72 : detailed ? 220 : 140)
            guard width > 0 else { return }
            let measured = resolved.measure(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            guard measured.width > 0, measured.height > 0,
                  measured.width + 6 <= viewport.width, measured.height + 4 <= viewport.height else { continue }
            let x = min(viewport.maxX - measured.width - 3, max(viewport.minX + 3, rect.midX - measured.width / 2))
            var candidates = [
                CGRect(x: x, y: rect.maxY + 6, width: measured.width, height: measured.height),
                CGRect(x: x, y: rect.minY - measured.height - 6, width: measured.width, height: measured.height)
            ]
            if chosen {
                let y = min(viewport.maxY - measured.height - 2, max(viewport.minY + 2, rect.maxY + 6))
                candidates.append(CGRect(x: x, y: y, width: measured.width, height: measured.height))
            }
            for destination in candidates {
                let background = destination.insetBy(dx: -3, dy: -2)
                guard viewport.contains(background), !occupied.contains(where: { $0.intersects(background) }) else { continue }
                context.fill(Path(roundedRect: background, cornerRadius: 3), with: .color(.white.opacity(0.88)))
                context.draw(resolved, in: destination)
                occupied.append(background.insetBy(dx: -3, dy: -3))
                return
            }
        }
        // Dense regions omit a label instead of covering another; details retain the full text.
    }

    private func drawCross(_ cross: MapCross, context: inout GraphicsContext, transform: MapTransform) {
        let point = transform.screen(CGPoint(x: CGFloat(cross.x), y: CGFloat(cross.y)))
        guard CGRect(origin: .zero, size: transform.size).insetBy(dx: -15, dy: -15).contains(point) else { return }
        let chosen = selectedID == MapSelection.cross(cross).id
        let color: Color
        let marker: String
        switch cross.state {
        case -1: color = .gray; marker = "×"
        case 0: color = .red; marker = "?"
        case 1: color = Color(red: 0.09, green: 0.57, blue: 0.31); marker = "+"
        case 2: color = Color(red: 0.12, green: 0.25, blue: 0.65); marker = "1→2"
        default: color = Color(red: 0.06, green: 0.54, blue: 0.77); marker = "2→1"
        }
        let directional = cross.state == 2 || cross.state == 3
        let width: CGFloat = directional ? 25 : 14
        let rect = CGRect(x: point.x - width / 2, y: point.y - 7, width: width, height: 14)
        let path = Path(roundedRect: rect, cornerRadius: 7)
        context.fill(path, with: .color(.white.opacity(0.96)))
        context.stroke(path, with: .color(color), lineWidth: chosen ? 3 : 1.5)
        context.draw(Text(marker).font(.system(size: directional ? 8 : 11, weight: .semibold)).foregroundColor(color), at: point)
    }

    private func hitTest(_ point: CGPoint, transform: MapTransform) -> MapSelection? {
        if showCrosses && (interaction.tool == .browse || interaction.tool == .cross) {
            let crosses = snapshot.crosses.filter { valid($0) && interaction.includes($0) }.map { cross in
                (cross, distance(point, transform.screen(CGPoint(x: CGFloat(cross.x), y: CGFloat(cross.y)))))
            }
            if let nearest = crosses.filter({ $0.1 <= 14 }).min(by: { $0.1 < $1.1 }) { return .cross(nearest.0) }
        }
        let nodes = snapshot.logicalNodes.filter { $0.x.isFinite && $0.y.isFinite }
            .filter { nodeRect($0, transform: transform).insetBy(dx: -8, dy: -8).contains(point) }
        if (interaction.tool == .browse || interaction.tool == .node), let node = nodes.min(by: {
            distance(point, transform.screen(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)))) < distance(point, transform.screen(CGPoint(x: CGFloat($1.x), y: CGFloat($1.y))))
        }) { return .logicalNode(node) }
        guard interaction.tool == .browse || interaction.tool == .line else { return nil }
        var nearest: MapLine?
        var nearestDistance: CGFloat = 10
        for line in snapshot.lines where line.nodes.count >= 2 {
            for index in 1..<line.nodes.count {
                let a = line.nodes[index - 1], b = line.nodes[index]
                let gap = segmentDistance(point, transform.screen(CGPoint(x: CGFloat(a.x), y: CGFloat(a.y))), transform.screen(CGPoint(x: CGFloat(b.x), y: CGFloat(b.y))))
                if gap < nearestDistance { nearestDistance = gap; nearest = line }
            }
        }
        return nearest.map { .line($0) }
    }

    private func scaleOverlay(transform: MapTransform) -> some View {
        HStack(alignment: .bottom) {
            Text("X \(coordinate(transform.center.x))  Y \(coordinate(transform.center.y))")
                .font(.system(size: 9, design: .monospaced))
                .accessibilityIdentifier("mapCoordinates")
                .padding(5)
                .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
            Spacer(minLength: 4)
            VStack(spacing: 3) {
                Text("\(coordinate(transform.gridStep)) 单位")
                    .font(.system(size: 9, design: .monospaced))
                    .accessibilityIdentifier("mapScale")
                    .accessibilityValue("每单位 \(coordinate(transform.scale)) 点")
                Rectangle().frame(width: transform.gridStep * transform.scale, height: 1)
            }
            .padding(5)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
        }
        .foregroundColor(Color(red: 0.25, green: 0.32, blue: 0.42))
    }

    private func valid(_ cross: MapCross) -> Bool {
        let position = cross.key.position
        return position.x2 >= 0 && position.x2 <= 1_000_000 && position.y2 >= 0 && position.y2 <= 1_000_000 &&
            position.x2 % 2 == 0 && position.y2 % 2 == 0 && (-1...3).contains(cross.state)
    }

    private func drawEditing(context: inout GraphicsContext, transform: MapTransform) {
        if !interaction.continuation.isEmpty {
            var route = Path()
            for (index, point) in interaction.continuation.enumerated() {
                let p = transform.screen(CGPoint(x: point.x, y: point.y))
                if index == 0 { route.move(to: p) } else { route.addLine(to: p) }
            }
            context.stroke(route, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, dash: [7, 4]))
        }
        if let preview = interaction.preview {
            for node in preview.logicalNodes { drawNode(node, context: &context, transform: transform) }
            for line in preview.lines { drawLine(line, context: &context, transform: transform) }
            for cross in preview.crosses { drawCross(cross, context: &context, transform: transform) }
        }
        if let region = interaction.region {
            let topLeft = transform.screen(CGPoint(x: region.left, y: region.top))
            let bottomRight = transform.screen(CGPoint(x: region.right, y: region.bottom))
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            context.fill(Path(rect), with: .color(.orange.opacity(0.08)))
            context.stroke(Path(rect), with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        if !interaction.draftPoints.isEmpty {
            var path = Path()
            for (index, point) in interaction.draftPoints.enumerated() {
                let p = transform.screen(CGPoint(x: point.x, y: point.y))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                let selected = index == interaction.selectedPoint
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                             with: .color(selected ? .red : .orange))
                context.draw(Text("\(index + 1)").font(.system(size: 10)).foregroundColor(.orange),
                             at: CGPoint(x: p.x + 10, y: p.y - 12))
            }
            context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        if let anchor = interaction.draftAnchor, interaction.showCursor {
            let snapped = MapLineDraft.snap(target: interaction.cursor, from: anchor)
            let a = transform.screen(anchor), b = transform.screen(snapped)
            var segment = Path(); segment.move(to: a); segment.addLine(to: b)
            context.stroke(segment, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            context.stroke(Path(ellipseIn: CGRect(x: b.x - 5, y: b.y - 5, width: 10, height: 10)), with: .color(.orange), lineWidth: 2)
        }
        if interaction.showCursor {
            let p = CGPoint(x: transform.size.width / 2, y: transform.size.height / 2)
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: p.x - 16, y: p.y)); crosshair.addLine(to: CGPoint(x: p.x + 16, y: p.y))
            crosshair.move(to: CGPoint(x: p.x, y: p.y - 16)); crosshair.addLine(to: CGPoint(x: p.x, y: p.y + 16))
            context.stroke(crosshair, with: .color(.white), lineWidth: 4)
            context.stroke(crosshair, with: .color(.red), lineWidth: 1)
        }
    }

    private func nodeRect(_ node: MapLogicalNode, transform: MapTransform) -> CGRect {
        let center = transform.screen(CGPoint(x: CGFloat(node.x), y: CGFloat(node.y)))
        let side = CGFloat(node.sideLength) * transform.scale
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    private func nodeColor(_ size: Int) -> Color {
        switch size {
        case 4: return Color(red: 0.40, green: 0.36, blue: 0.65)
        case 6: return Color(red: 0.48, green: 0.23, blue: 0.77)
        case 8: return Color(red: 0.03, green: 0.57, blue: 0.70)
        case 10: return Color(red: 0.71, green: 0.33, blue: 0.04)
        case 18: return Color(red: 0.08, green: 0.52, blue: 0.29)
        default: return Color(red: 0.16, green: 0.38, blue: 0.67)
        }
    }

    private func nodePath(rect: CGRect, size: Int, cut: CGFloat) -> Path {
        guard size == 8 || size == 10 else { return Path(roundedRect: rect, cornerRadius: cut) }
        let l = rect.minX, r = rect.maxX, t = rect.minY, b = rect.maxY, c = cut
        var path = Path()
        path.move(to: CGPoint(x: l + c, y: t)); path.addLine(to: CGPoint(x: r - c, y: t))
        if size == 8 { path.addLine(to: CGPoint(x: r, y: t + c)) }
        else { path.addCurve(to: CGPoint(x: r, y: t + c), control1: CGPoint(x: r - c, y: t + c * 0.55228475), control2: CGPoint(x: r - c * 0.55228475, y: t + c)) }
        path.addLine(to: CGPoint(x: r, y: b - c))
        if size == 8 { path.addLine(to: CGPoint(x: r - c, y: b)) }
        else { path.addCurve(to: CGPoint(x: r - c, y: b), control1: CGPoint(x: r - c * 0.55228475, y: b - c), control2: CGPoint(x: r - c, y: b - c * 0.55228475)) }
        path.addLine(to: CGPoint(x: l + c, y: b))
        if size == 8 { path.addLine(to: CGPoint(x: l, y: b - c)) }
        else { path.addCurve(to: CGPoint(x: l, y: b - c), control1: CGPoint(x: l + c, y: b - c * 0.55228475), control2: CGPoint(x: l + c * 0.55228475, y: b - c)) }
        path.addLine(to: CGPoint(x: l, y: t + c))
        if size == 8 { path.addLine(to: CGPoint(x: l + c, y: t)) }
        else { path.addCurve(to: CGPoint(x: l + c, y: t), control1: CGPoint(x: l + c * 0.55228475, y: t + c), control2: CGPoint(x: l + c, y: t + c * 0.55228475)) }
        path.closeSubpath(); return path
    }

    private func shortened(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
    private func coordinate(_ number: CGFloat) -> String { String(format: "%.0f", Double(number)) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func segmentBounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func clippedSegment(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        let dx = b.x - a.x, dy = b.y - a.y
        var lower: CGFloat = 0, upper: CGFloat = 1
        let edges: [(CGFloat, CGFloat)] = [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x),
                                          (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)]
        for (direction, margin) in edges {
            if direction == 0 { if margin < 0 { return nil }; continue }
            let fraction = margin / direction
            if direction < 0 { lower = max(lower, fraction) } else { upper = min(upper, fraction) }
            if lower > upper { return nil }
        }
        return (CGPoint(x: a.x + lower * dx, y: a.y + lower * dy),
                CGPoint(x: a.x + upper * dx, y: a.y + upper * dy))
    }
    private func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, a) }
        let fraction = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return distance(point, CGPoint(x: a.x + fraction * dx, y: a.y + fraction * dy))
    }
}

struct MapTransform {
    // At maximum zoom, one integer coordinate step is clearly visible on a phone.
    static let maximumScale: CGFloat = 128

    let center: CGPoint
    let scale: CGFloat
    let size: CGSize
    func screen(_ world: CGPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + (world.x - center.x) * scale,
                y: size.height / 2 - (world.y - center.y) * scale)
    }
    func world(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (screen.x - size.width / 2) / scale,
                y: center.y - (screen.y - size.height / 2) / scale)
    }
    var gridStep: CGFloat {
        let target = 72 / scale
        let power = pow(10, floor(log10(target)))
        let unit = target / power
        return max(1, (unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 5 ? 5 : 10) * power)
    }
}
