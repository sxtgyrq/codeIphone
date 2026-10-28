import SwiftUI

/// Label-based initializer keeps the native menu appearance on iOS 16 too.
struct MapMenuButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = systemImage; self.action = action
    }
    var body: some View { Button(action: action) { Label(title, systemImage: symbol) } }
}

@MainActor
struct MapCoordinateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var x: String
    @State private var y: String
    let onApply: (CGPoint) -> Void
    init(point: CGPoint, onApply: @escaping (CGPoint) -> Void) {
        _x = State(initialValue: String(format: "%.1f", Double(point.x)))
        _y = State(initialValue: String(format: "%.1f", Double(point.y)))
        self.onApply = onApply
    }
    private var point: CGPoint? {
        guard let px = Double(x), let py = Double(y), px.isFinite, py.isFinite,
              (0...500_000).contains(px), (0...500_000).contains(py) else { return nil }
        return CGPoint(x: px, y: py)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("地图中心 / 准星位置") {
                    coordinateField("X", text: $x, identifier: "cursorX")
                    coordinateField("Y", text: $y, identifier: "cursorY")
                    if point == nil {
                        Label("请输入 0…500000 之间的有效数字。", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    HStack {
                        nudge("左移 1", icon: "arrow.left", dx: -1, dy: 0)
                        nudge("下移 1", icon: "arrow.down", dx: 0, dy: -1)
                        nudge("上移 1", icon: "arrow.up", dx: 0, dy: 1)
                        nudge("右移 1", icon: "arrow.right", dx: 1, dy: 0)
                    }.buttonStyle(.bordered)
                    Text("坐标范围 0…500000。线路落点吸附整数及八方向，LN 中心吸附到整数＋0.5。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("精确定位").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { if let point { onApply(point); dismiss() } }
                        .disabled(point == nil).accessibilityIdentifier("applyCoordinates")
                }
            }
        }
    }
    private func coordinateField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(title).font(.body.monospaced())
            TextField(title, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier(identifier)
            Button { text.wrappedValue = "" } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel("清空 " + title).accessibilityIdentifier("clear-" + identifier)
        }
    }
    private func nudge(_ title: String, icon: String, dx: Double, dy: Double) -> some View {
        Button {
            guard let point else { return }
            x = String(format: "%.1f", min(500_000, max(0, Double(point.x) + dx)))
            y = String(format: "%.1f", min(500_000, max(0, Double(point.y) + dy)))
        } label: { Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 44) }
        .accessibilityLabel(title)
    }
}

@MainActor
struct MapObjectBrowser: View {
    let snapshot: MapSnapshot
    let tool: MapTool
    let onChoose: (MapSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                if tool == .line || tool == .browse {
                    Section("线路 · \(snapshot.lines.count)") {
                        ForEach(snapshot.lines.filter { matches($0.code + $0.properties.roadName + $0.owner) }) { line in
                            Button { choose(.line(line)) } label: {
                                Label { VStack(alignment: .leading) {
                                    Text(line.properties.roadName.isEmpty ? line.code : line.properties.roadName).foregroundStyle(.primary)
                                    Text("\(line.nodes.count) 个节点 · \(line.owner)\(line.isLocked ? " · 已锁定" : "")").font(.caption).foregroundStyle(.secondary)
                                }} icon: { Image(systemName: line.isLocked ? "lock" : "point.topleft.down.to.point.bottomright.curvepath") }
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("line-\(line.code)")
                        }
                    }
                }
                if tool == .node || tool == .browse {
                    Section("逻辑节点 · \(snapshot.logicalNodes.count)") {
                        ForEach(snapshot.logicalNodes.filter { matches($0.code + $0.properties.value + $0.properties.logicLanguage) }) { node in
                            Button { choose(.logicalNode(node)) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("LN\(node.sideLength) · \(node.properties.value)").foregroundStyle(.primary)
                                    Text(node.properties.logicLanguage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("node-\(node.code)")
                        }
                    }
                }
                if tool == .cross || tool == .browse {
                    Section("Cross · \(snapshot.crosses.count)") {
                        ForEach(snapshot.crosses.filter { matches($0.key.roadCode1 + $0.key.roadCode2 + $0.stateLabel) }) { cross in
                            Button { choose(.cross(cross)) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("(\(cross.key.position.x2 / 2), \(cross.key.position.y2 / 2)) · \(cross.stateLabel)").foregroundStyle(.primary)
                                    Text("\(cross.key.roadCode1) / \(cross.key.roadCode2)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("cross-\(cross.key.roadCode1)-\(cross.key.roadCode2)")
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "名称、逻辑语言或编码")
            .navigationTitle(tool == .browse ? "地图对象" : tool.rawValue + "列表").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private func choose(_ selection: MapSelection) { onChoose(selection); dismiss() }
}

struct MapTouchGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("从桌面到触摸") {
                    Text("地图保持在中央。底部选择工具，轻点对象后出现相关操作；长任务按步骤预览、确认。拖动平移，双指缩放。")
                    Text("放置时将地图移动到中央准星下，点“确认落点”。精确坐标可直接输入，并可逐单位微调。")
                }
                Section("线路") {
                    row("3 / 4", "线路 → 新建，直接进入草稿")
                    row("A / 5", "加点 / 更多 → 切换前端或末端")
                    row("T / E / R", "更多 → 自动插入到准星；也可在节点列表选节点后插点、移动或删除")
                    row("F6 / Backspace / Esc", "保存 / 取消；草稿撤回可以只退一个点")
                    row("F8 / F9", "线路工具 → 点选线路 → 编辑节点")
                    row("E / C / D / B / L", "选中线路 → 属性、反向、拆分、合并、锁定")
                }
                Section("Cross") {
                    row("K / F3", "计算交点 / 刷新")
                    row("U / Tab", "Cross 工具 → 点交点 → 选择同位置的线路关系")
                    row("I / O / P", "双向连通 / 不连通 / 未设置")
                    row("Enter / 【", "直接选择所需的“线路 A → 线路 B”单向通行")
                    row("Shift＋状态键", "保存后自动同步，后台计算让前台操作优先")
                }
                Section("LN 与区域") {
                    row("F5 / A", "LN → 新增 → 选类型 → 落点；可开启连续放置")
                    row("7 / E", "点选 LN → 编辑；支持移动、删除、定位和连接")
                    row("J / F4 / G", "重算关联 / 刷新 / 显示保护区域")
                    row("F7", "区域 → 选择两个角 → 移动、复制或删除")
                    row("Ctrl+C / Ctrl+V", "选中对象 → 复制，再用更多 → 粘贴副本选择新落点")
                    row("Ctrl+Z", "顶部撤销按钮，撤销本账号最近的数据库操作")
                }
                Section("视图与更多") {
                    row("1 / 8 / 9 / 0", "显示面板：箭头、速度、LN标签、三类Cross；编辑中用顶部更多 → 显示与计算")
                    row("+ / − / Home / F2", "双指缩放或缩放按钮 / 回中心 / 刷新")
                    row("Ctrl+F1 / F1", "更多 → 收起工具栏 / 操作说明")
                    Text("更多中可导入 ArgumentMap Flow JSON，先预览再整体保存。账号菜单可退出后重新登录。")
                    NavigationLink("流程图格式与完整说明") {
                        ScrollView { Text(flowGuide).font(.body).textSelection(.enabled).padding() }.navigationTitle("流程图说明")
                    }
                }
                Section("版本") { Text(AppRelease.title); Text("构建 \(AppRelease.build)").foregroundStyle(.secondary) }
            }.navigationTitle("触摸操作指南").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
    private func row(_ keys: String, _ touch: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(touch); Text("电脑版：" + keys).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 3)
    }
    private var flowGuide: String {
        guard let url = Bundle.main.url(forResource: "FlowDiagramLanguage", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "导入使用 argumentmap.flow/1 JSON，包含 ln、roads 和 crosses。" }
        return text
    }
}

enum MapPreviewTransform {
    static func shifted(_ map: MapSnapshot, dx: Int, dy: Int) -> MapSnapshot {
        let lines = map.lines.map { line in
            MapLine(code: line.code, owner: line.owner, isLocked: line.isLocked, version: line.version,
                    nodes: line.nodes.map { MapLinePoint(lineCode: $0.lineCode, order: $0.order, x: $0.x + dx, y: $0.y + dy) },
                    properties: line.properties)
        }
        let nodes = map.logicalNodes.map { node in
            MapLogicalNode(code: node.code, owner: node.owner, version: node.version, x: node.x + Double(dx), y: node.y + Double(dy),
                           sideLength: node.sideLength, properties: node.properties, positions: [], canEdit: node.canEdit)
        }
        let crosses = map.crosses.map { cross in
            MapCross(key: MapCrossKey(roadCode1: cross.key.roadCode1, roadCode2: cross.key.roadCode2,
                                     position: MapCrossPosition(x2: cross.key.position.x2 + dx * 2, y2: cross.key.position.y2 + dy * 2)),
                     roadOrder1: cross.roadOrder1, roadOrder2: cross.roadOrder2, roadVersion1: cross.roadVersion1,
                     roadVersion2: cross.roadVersion2, state: cross.state, version: cross.version,
                     percent1: cross.percent1, percent2: cross.percent2)
        }
        return MapSnapshot(lines: lines, logicalNodes: nodes, crosses: crosses)
    }
}

@MainActor
struct MapSplitEditor: View {
    let line: MapLine
    let onSave: (Int) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = MapInteraction()
    @State private var cut: Int?
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("选择断开处") {
                    Text("选择第二条线路的起始节点。两侧各保留至少两个节点，服务端会同步 Cross 和 LN 关联。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(line.nodes.filter { $0.order >= 2 && $0.order <= line.nodes.count - 2 }) { point in
                        Button {
                            guard let split = Self.previewSnapshot(line: line, cutBeforeOrder: point.order) else { return }
                            cut = point.order
                            preview.selectedID = MapSelection.line(split.lines[1]).id
                            preview.locate(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
                        } label: {
                            HStack {
                                Text("节点 \(point.order + 1) 前 · (\(point.x), \(point.y))")
                                Spacer(); if cut == point.order { Image(systemName: "checkmark") }
                            }.frame(minHeight: 44)
                        }.disabled(saving)
                    }
                }
                if let cut, let split = Self.previewSnapshot(line: line, cutBeforeOrder: cut) {
                    Section("拆分预览") {
                        MapCanvasView(interaction: preview, snapshot: split, showArrows: true,
                                      showLabels: false, showCrosses: false, fitRequest: 0,
                                      onSelect: { _ in preview.selectedID = MapSelection.line(split.lines[1]).id })
                            .frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text("第一条保留节点 1–\(cut)，第二条从节点 \(cut + 1) 开始；两者之间的线段被断开。")
                            .font(.footnote)
                        Text("蓝色为第一条，橙色为第二条。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("拆分线路").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "保存中…" : "确认拆分") {
                            guard let cut else { return }; saving = true
                            Task { do { try await onSave(cut); dismiss() } catch { self.error = error.localizedDescription }; saving = false }
                        }.disabled(cut == nil || saving).accessibilityIdentifier("saveSplit")
                    }
                }.interactiveDismissDisabled(saving)
        }
    }

    /// Mirrors Server Take(cut)/Skip(cut): the joining segment is removed,
    /// without adding a shared endpoint or predicting the new persisted code.
    nonisolated static func previewSnapshot(line: MapLine, cutBeforeOrder cut: Int) -> MapSnapshot? {
        guard line.isValidGeometry, cut >= 2, cut <= line.nodes.count - 2 else { return nil }
        func part(code: String, points: ArraySlice<MapLinePoint>) -> MapLine {
            MapLine(code: code, owner: line.owner, isLocked: line.isLocked, version: line.version,
                    nodes: points.enumerated().map {
                        MapLinePoint(lineCode: code, order: $0.offset, x: $0.element.x, y: $0.element.y)
                    }, properties: line.properties)
        }
        return MapSnapshot(lines: [
            part(code: line.code, points: line.nodes.prefix(cut)),
            part(code: line.code + "-split-preview", points: line.nodes.suffix(from: cut))
        ])
    }
}
