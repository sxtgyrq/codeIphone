import SwiftUI

private enum MapPlacement {
    case none, newNode(Int), instance(MapLogicalNode), moveNode(MapLogicalNode), copyNode(MapLogicalNode)
    case pasteLine(MapLineCopyData), areaFirst, areaSecond(CGPoint), moveArea(MapAreaSelection), pasteArea(MapAreaSelection)
    var active: Bool { if case .none = self { return false }; return true }
}
private enum MapClipboard { case line(MapLineCopyData), node(MapLogicalNode), area(MapAreaSelection) }
private enum WorkspaceSheet: Identifiable {
    case coordinates, sizes, points, objects, nodes, help, flow
    case node(MapLogicalNode), newNode(Int, CGPoint), cross(MapCross), properties(MapLine), details(MapSelection)
    case merge(MapLine, MapLine?), connection(MapLogicalNode?, MapLogicalNode?), split(MapLine)
    var id: String { String(describing: self) }
}

/// Native document workspace: the canvas stays central and the command dock
/// follows the selected object. Keyboard shortcuts never gate an operation.
@MainActor
struct MapWorkspace: View {
    @ObservedObject var model: MapViewModel
    @StateObject private var interaction = MapInteraction()
    @State private var sheet: WorkspaceSheet?
    @State private var selection: MapSelection?
    @State private var draft: MapLineDraft?
    @State private var history: [MapLineDraft] = []
    @State private var placement = MapPlacement.none
    @State private var area: MapAreaSelection?
    @State private var clipboard: MapClipboard?
    @State private var connectionSource: MapLogicalNode?
    @State private var mergeSource: MapLine?
    @State private var showArrows = true
    @State private var showLabels = true
    @State private var showCrosses = true
    @State private var toolsVisible = true
    @State private var continuousNodes = false
    @State private var lastNodeTemplate: MapNodeEditorDraft?
    @State private var fitRequest = 0
    @State private var running = false
    @State private var localError: String?
    @State private var localNotice: String?
    @State private var showingConfirmation = false
    @State private var confirmationTitle = ""
    @State private var confirmationAction: (() -> Void)?

    private var map: MapSnapshot { model.snapshot ?? .empty }
    private var busy: Bool { model.isWorking || running }
    private var editing: Bool { draft != nil || placement.active || connectionSource != nil || mergeSource != nil }
    private var canWrite: Bool { !busy && !model.requiresRefreshBeforeWrite && !model.hasPendingUndo }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                ZStack {
                    MapCanvasView(interaction: interaction, snapshot: map, showArrows: showArrows,
                                  showLabels: showLabels, showCrosses: showCrosses, fitRequest: fitRequest,
                                  onSelect: select, onPoint: tappedPoint)
                    if model.snapshot == nil {
                        VStack(spacing: 12) {
                            if busy { ProgressView() }
                            Text("地图尚未加载")
                            Button("重新加载") { model.refresh() }.buttonStyle(.borderedProminent)
                        }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    } else if map.isEmpty && !editing {
                        VStack(spacing: 8) {
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle)
                            Text("地图暂时为空").font(.headline)
                            Text("从底部选择线路或 LN，开始绘制。").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false)
                    }
                    if busy {
                        VStack { HStack { Spacer(); ProgressView().padding(12).background(.regularMaterial, in: Capsule()) }; Spacer() }.padding().allowsHitTesting(false)
                    }
                }
                commandDock
            }
            .navigationTitle("逻辑地图").navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationTools }
            .sheet(item: $sheet, content: sheetContent)
            .alert("未完成操作", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("知道了", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
            .confirmationDialog(confirmationTitle, isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button(confirmationTitle.hasPrefix("撤销") ? "确认撤销" : "确认", role: .destructive) { confirmationAction?() }
                Button("取消", role: .cancel) {}
            }
            .onChange(of: draft) { _ in synchronizePreview() }
            .onChange(of: interaction.cursor) { _ in synchronizePreview() }
            .onChange(of: model.snapshot) { _ in refreshSelection() }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("线路 \(map.lines.count) · LN \(map.logicalNodes.count) · Cross \(map.crosses.count)")
                    .font(.caption).accessibilityIdentifier("mapCounts")
                Spacer()
                if let time = model.lastRefresh { Text(time, style: .time).font(.caption2).foregroundStyle(.secondary) }
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).accessibilityIdentifier("mapError")
            } else if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2).accessibilityIdentifier("mapNotice")
            }
            if let localNotice { Text(localNotice).font(.caption).foregroundStyle(.secondary) }
            if model.requiresRefreshBeforeWrite {
                Button("刷新地图，保留草稿") { model.refresh() }
                    .disabled(busy).accessibilityIdentifier("recoverRefresh")
            }
            if let progress = model.calculationStatus {
                HStack {
                    if model.isCalculating { ProgressView().scaleEffect(0.7) }
                    Text(progress).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    if model.isCalculating { Button("停止") { model.stopCalculation() }.font(.caption).frame(minHeight: 32) }
                }.accessibilityIdentifier("calculationStatus")
            }
        }.padding(.horizontal, 16).padding(.vertical, 7).background(.regularMaterial)
    }

    @ToolbarContentBuilder private var navigationTools: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text("逻辑地图").font(.headline)
                Text(AppRelease.title).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("releaseVersion")
            }
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Menu {
                Text(model.session?.userName ?? "")
                Text(model.serverAddress)
                Text("\(AppRelease.title) · 构建 \(AppRelease.build)")
                Button("退出登录", role: .destructive) {
                    if editing { confirm("放弃当前草稿并退出登录？") { model.logout() } }
                    else { model.logout() }
                }.disabled(busy).accessibilityIdentifier("logoutButton")
            } label: { Label("账号", systemImage: "person.crop.circle") }
            .accessibilityIdentifier("accountMenu")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                if draft != nil { undoDraft() }
                else { confirm("撤销本账号上一次数据库操作？") { run { try await model.undoLastOperation(); clearOperation() } } }
            } label: { Image(systemName: "arrow.uturn.backward") }
            .accessibilityLabel(draft != nil ? "撤回草稿一步" : "撤销上次操作")
            .disabled(busy || (editing && draft == nil) || (draft != nil && history.isEmpty))
            .accessibilityIdentifier("undoMap")
            Menu {
                MapMenuButton("刷新地图（保留草稿）", systemImage: "arrow.clockwise") { model.refresh() }.disabled(busy)
                if let draft, draft.version >= 0 {
                    Button("重新加载当前线路") {
                        confirm("放弃本地修改，重新加载当前线路？", action: reloadDraft)
                    }.disabled(busy)
                }
                MapMenuButton("节点列表", systemImage: "list.bullet") { sheet = .nodes }.accessibilityIdentifier("nodesButton")
                MapMenuButton("地图对象列表", systemImage: "square.grid.2x2") { sheet = .objects }
                MapMenuButton("精确定位", systemImage: "scope") { sheet = .coordinates }
                Divider()
                MapMenuButton("导入流程图", systemImage: "square.and.arrow.down") { sheet = .flow }.disabled(editing || !canWrite)
                MapMenuButton("粘贴", systemImage: "doc.on.clipboard", action: beginPaste).disabled(clipboard == nil || editing || !canWrite)
                MapMenuButton("回到地图中心", systemImage: "location") { interaction.locate(CGPoint(x: 250_000, y: 250_000)) }
                MapMenuButton("放大", systemImage: "plus.magnifyingglass") { interaction.zoomRequest = max(0, interaction.zoomRequest) + 1 }
                MapMenuButton("缩小", systemImage: "minus.magnifyingglass") { interaction.zoomRequest = min(0, interaction.zoomRequest) - 1 }
                MapMenuButton(toolsVisible ? "收起工具栏" : "展开工具栏", systemImage: "rectangle.bottomthird.inset.filled") { toolsVisible.toggle() }
                Divider()
                MapMenuButton("触摸操作指南", systemImage: "questionmark.circle") { sheet = .help }
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("更多").accessibilityIdentifier("moreTools")
        }
    }

    private var commandDock: some View {
        VStack(spacing: 0) {
            if editing {
                editingDock
            } else if area != nil && interaction.tool == .area {
                areaDock
            } else if let selection {
                selectionDock(selection)
            } else if toolsVisible {
                idleDock
            }
            if toolsVisible && !editing {
                Divider()
                HStack(spacing: 0) {
                    ForEach(MapTool.allCases) { tool in
                        Button { chooseTool(tool) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tool.symbol).font(.system(size: 18, weight: .medium))
                                Text(tool.rawValue).font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
                                .foregroundStyle(interaction.tool == tool ? Color.accentColor : Color.secondary)
                        }.accessibilityIdentifier("tool-\(toolID(tool))")
                            .accessibilityAddTraits(interaction.tool == tool ? .isSelected : [])
                    }
                }
            } else if !editing {
                Button { toolsVisible = true } label: { Label("展开工具", systemImage: "chevron.up").frame(minHeight: 44) }
            }
        }.padding(.horizontal, 12).background(.regularMaterial)
    }

    private var idleDock: some View {
        VStack(spacing: 2) {
            if interaction.tool != .browse {
                Text(toolHint).font(.caption).foregroundStyle(.secondary).padding(.top, 7)
            }
            HStack {
                switch interaction.tool {
                case .browse:
                    dockButton("查看全部", "arrow.up.left.and.arrow.down.right", id: "fitMap") { fitRequest += 1 }
                case .line:
                    dockButton("新建线路", "plus", id: "newLine", disabled: !canWrite) { beginNewLine() }
                case .node:
                    dockButton("新增 LN", "plus", id: "newNode", disabled: !canWrite) { sheet = .sizes }
                case .cross:
                    dockButton("计算交点", "arrow.triangle.branch", id: "calculateCross", disabled: model.isCalculating || !canWrite) { model.startCalculation(.cross) }
                case .area:
                    dockButton("开始框选", "rectangle.dashed", id: "beginArea", disabled: !canWrite) { setPlacement(.areaFirst) }
                }
                Spacer(minLength: 2)
                if interaction.tool == .browse {
                    dockButton("刷新", "arrow.clockwise", id: "refreshMap", disabled: busy) { model.refresh() }
                } else {
                    dockButton("列表", "list.bullet", id: "objectList") { sheet = .objects }
                }
                Spacer(minLength: 2)
                displayMenu
            }
        }
    }

    private var displayMenu: some View {
        Menu {
            Toggle("线路箭头", isOn: $showArrows).onChange(of: showArrows) { if !$0 { interaction.showSpeeds = false } }
            Toggle("线路速度", isOn: $interaction.showSpeeds).onChange(of: interaction.showSpeeds) { if $0 { showArrows = true } }
            Toggle("LN 标签", isOn: $showLabels)
            Toggle("LN 保护区域", isOn: $interaction.showProtection)
            Toggle("Cross 交点", isOn: $showCrosses)
            Toggle("连通（含单向）", isOn: $interaction.connected)
            Toggle("不连通", isOn: $interaction.disconnected)
            Toggle("未设置", isOn: $interaction.unset)
            Divider()
            MapMenuButton("刷新全部", systemImage: "arrow.clockwise") { model.refresh() }.disabled(busy)
            MapMenuButton("查看全部", systemImage: "arrow.up.left.and.arrow.down.right") { fitRequest += 1 }
            Button("计算交点") { model.startCalculation(.cross) }.disabled(model.isCalculating || !canWrite)
            Button("重算 LN 关联") { model.startCalculation(.logicalNodes) }.disabled(model.isCalculating || !canWrite)
            Toggle("连续放置 LN", isOn: $continuousNodes)
        } label: { Label("显示", systemImage: "slider.horizontal.3").font(.subheadline).frame(minHeight: 44) }
        .accessibilityIdentifier("displayMenu")
    }

    private func selectionDock(_ item: MapSelection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectionTitle(item)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { selection = nil; interaction.selectedID = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 36) }
                    .accessibilityLabel("取消选择")
            }
            HStack {
                dockButton("编辑", "pencil", id: "selectedEdit", disabled: !canWrite) { editSelection(item) }
                Spacer()
                dockButton("资料", "info.circle", id: "selectedDetails") { sheet = .details(item) }
                Spacer()
                Menu {
                    switch item {
                    case .line(let line):
                        Button("线路属性") { sheet = .properties(line) }.accessibilityIdentifier("lineProperties")
                        Button("复制线路") { clipboard = .line(MapLineCopyData(line: line)); selection = nil; interaction.selectedID = nil }
                        Button("反转方向") { run { _ = try await model.execute("已反转线路") { try await $0.reverseLine(lineCode: line.code, version: line.version, session: $1) } } }.disabled(!canEdit(line))
                        Button("拆分线路") { sheet = .split(line) }.disabled(!canEdit(line) || line.nodes.count < 4)
                        Button("合并线路") { mergeSource = line; selection = nil; interaction.tool = .line }.disabled(!canEdit(line))
                        Button(line.isLocked ? "解锁线路" : "锁定线路") { run { _ = try await model.execute("已更新锁定状态") { try await $0.toggleLineLock(lineCode: line.code, version: line.version, session: $1) } } }
                        Button("删除线路", role: .destructive) { confirm("删除线路 \(line.code)？") { run { _ = try await model.execute("已删除线路") { try await $0.deleteLine(lineCode: line.code, version: line.version, session: $1) }; selection = nil } } }.disabled(!canEdit(line))
                    case .logicalNode(let node):
                        Button("移动节点") { setPlacement(.moveNode(node)) }.disabled(!canEdit(node))
                        Button("复制节点") { clipboard = .node(node); selection = nil }.disabled(node.sideLength == 18)
                        Button("连接另一个 LN") { beginConnection(node) }
                        if node.sideLength == 12 && MapNodeEditorRules.canInstantiate(node) {
                            Button("创建该类的实例") { setPlacement(.instance(node)) }
                        }
                        Button("删除节点", role: .destructive) { confirm("删除 LN \(node.code)？") { run { _ = try await model.execute("已删除节点") { try await $0.deleteLogicalNode(node: node, session: $1) }; selection = nil } } }.disabled(!canEdit(node))
                    case .cross(let cross):
                        Button("设置通行 / 选择同位置关系") { sheet = .cross(cross) }
                        Button("计算交点") { model.startCalculation(.cross) }.disabled(model.isCalculating)
                    }
                    Divider()
                    Button("定位对象") { locate(item) }
                    Button("粘贴") { beginPaste() }.disabled(clipboard == nil)
                    Button("刷新") { model.refresh() }
                } label: { Label("更多", systemImage: "ellipsis").font(.subheadline).frame(minHeight: 44) }
                .disabled(busy).accessibilityIdentifier("selectedMore")
            }
        }
    }

    private var editingDock: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(editingHint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                if draft != nil || placement.active {
                    Button { sheet = .coordinates } label: { Image(systemName: "scope").frame(width: 44, height: 40) }
                        .accessibilityLabel("精确坐标").accessibilityIdentifier("coordinatesButton")
                }
            }.padding(.top, 4)
            if draft != nil {
                HStack {
                    dockButton("加点", "plus.circle.fill", id: "addPoint", disabled: busy) { mutateDraft { try $0.addPoint(interaction.cursor) } }
                    Spacer()
                    dockButton("节点", "list.number", id: "draftPoints", disabled: busy) { sheet = .points }
                    Spacer()
                    Menu {
                        Button(draft?.addFromStart == true ? "切换到末端加点" : "切换到前端加点") { mutateDraft { $0.addFromStart.toggle() } }
                        Button("移动选中节点到准星", action: moveDraftPoint).disabled(interaction.selectedPoint == nil)
                        Button("在选中节点后插点") { if let index = interaction.selectedPoint { mutateDraft { try $0.insertPoint(interaction.cursor, after: index) } } }.disabled(interaction.selectedPoint == nil)
                        Button("删除选中节点", role: .destructive) { if let index = interaction.selectedPoint { mutateDraft { try $0.removePoint(at: index) }; interaction.selectedPoint = nil } }.disabled(interaction.selectedPoint == nil)
                        Button("反转草稿方向") { mutateDraft { $0.reverse() } }
                        Button("撤回草稿一步", action: undoDraft).disabled(history.isEmpty)
                    } label: { Label("更多", systemImage: "ellipsis").frame(minHeight: 44) }.disabled(busy).accessibilityIdentifier("draftMore")
                }
            }
            HStack {
                dockButton("取消", "xmark", id: "cancelDraft", disabled: busy, action: cancelOperation)
                Spacer()
                if draft != nil {
                    Button("保存线路", action: saveDraft).buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(!canWrite || draft?.validationMessage != nil).accessibilityIdentifier("saveDraft")
                } else if placement.active {
                    Button(placementButton, action: confirmPlacement).buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(!canWrite).accessibilityIdentifier("placementConfirm")
                } else {
                    Button("从列表选择") { sheet = .objects }.frame(minHeight: 44)
                }
            }
        }
    }

    private var areaDock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let area {
                Text("选中 \(area.lines.count) 条线路 · \(area.logicalNodes.count) 个 LN · \(area.crosses.count) 个 Cross")
                    .font(.caption).padding(.top, 8).accessibilityIdentifier("areaCounts")
                HStack {
                    dockButton("移动", "arrow.up.and.down.and.arrow.left.and.right", id: "areaMove", disabled: !canWrite) { setPlacement(.moveArea(area)) }
                    Spacer()
                    dockButton("复制", "doc.on.doc", id: "areaCopy") { clipboard = .area(area); self.area = nil; interaction.region = nil }
                    Spacer()
                    Menu {
                        Button("删除整组", role: .destructive) { confirm("删除框选中的全部对象？") { run { _ = try await model.execute("已删除框选对象") { try await $0.deleteMapArea(selection: area, session: $1) }; clearOperation() } } }.disabled(!canWrite).accessibilityIdentifier("areaDelete")
                        Button("重新框选") { self.area = nil; setPlacement(.areaFirst) }
                        Button("取消选择") { self.area = nil; interaction.region = nil }
                    } label: { Label("更多", systemImage: "ellipsis").frame(minHeight: 44) }
                }
            }
        }
    }

    private func dockButton(_ title: String, _ icon: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.subheadline).frame(minHeight: 44).contentShape(Rectangle()) }
            .disabled(disabled).accessibilityIdentifier(id)
    }

    @ViewBuilder private func sheetContent(_ item: WorkspaceSheet) -> some View {
        switch item {
        case .coordinates:
            MapCoordinateEditor(point: interaction.cursor) { interaction.locate($0) }.presentationDetents([.medium, .large])
        case .help: MapTouchGuide()
        case .sizes: sizeChooser
        case .objects: MapObjectBrowser(snapshot: map, tool: interaction.tool, onChoose: selectFromList)
        case .nodes: MapNodeList(nodes: map.logicalNodes) { selectFromList(.logicalNode($0)) }
        case .details(let selected): MapObjectDetails(selection: selected)
        case .cross(let cross):
            MapCrossEditor(cross: cross, relatedCrosses: map.crosses, lines: map.lines, onSave: { cross, state in
                _ = try await model.execute("已更新交点通行") { try await $0.editCross(cross: cross, state: state, session: $1) }
            }, onLocateLine: { locate(.line($0)); selection = .line($0); interaction.tool = .line })
        case .properties(let line):
            MapLinePropertiesEditor(line: line) { properties in
                _ = try await model.execute("已更新线路属性") { try await $0.saveLineProperties(lineCode: line.code, version: line.version, properties: properties, session: $1) }
            }
        case .node(let node): nodeEditor(node)
        case .newNode(let size, let point):
            MapNodeEditor(userName: model.session?.userName ?? "", allNodes: map.logicalNodes, center: point, sideLength: size) { value in
                _ = try await model.execute("已新增 LN") { try await $0.createLogicalNode(x: value.x, y: value.y, sideLength: value.sideLength, properties: value.properties, instanceParentCode: value.instanceParentCode, session: $1) }
                lastNodeTemplate = value
                if continuousNodes && value.sideLength != 18 { setPlacement(.newNode(value.sideLength)) } else { clearOperation() }
            }
        case .points:
            if let current = draft {
                MapLinePointList(draft: Binding(get: { draft ?? current }, set: { value in if let old = draft { history.append(old) }; draft = value; interaction.selectedPoint = nil })) { index in
                    interaction.selectedPoint = index
                    if let point = draft?.points[index] { interaction.locate(CGPoint(x: point.x, y: point.y)) }
                    sheet = nil
                }
            }
        case .merge(let first, let second): MapMergeEditor(model: model, first: first, second: second) { clearOperation() }
        case .connection(let source, let target): MapConnectionEditor(model: model, source: source, target: target) { clearOperation() }
        case .flow: MapFlowImportEditor(model: model, center: interaction.cursor) { clearOperation() }
        case .split(let line): splitChooser(line)
        }
    }

    private func nodeEditor(_ node: MapLogicalNode) -> some View {
        MapNodeEditor(node: node, userName: model.session?.userName ?? "", allNodes: map.logicalNodes,
                      center: CGPoint(x: node.x, y: node.y), onSave: { value in
            _ = try await model.execute("已更新 LN") { try await $0.updateLogicalNode(node: node, properties: value.properties, session: $1) }
        }, onDelete: { selected in
            _ = try await model.execute("已删除 LN") { try await $0.deleteLogicalNode(node: selected, session: $1) }; selection = nil
        }, onMove: { setPlacement(.moveNode($0)) }, onLocate: { locate(.logicalNode($0)) },
        onCopy: { clipboard = .node($0); selection = nil }, onConnect: beginConnection,
        onCreateInstance: { setPlacement(.instance($0)) })
    }

    private var sizeChooser: some View {
        NavigationStack {
            List {
                Section("选择要放置的逻辑节点") {
                    ForEach([4, 6, 8, 10, 12, 18], id: \.self) { size in
                        Button { sheet = nil; lastNodeTemplate = nil; setPlacement(.newNode(size)) } label: {
                            HStack(spacing: 14) {
                                Text("\(size)").font(.title2.monospaced().bold()).frame(width: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(nodeTypeTitle(size)).foregroundStyle(.primary)
                                    Text("LN\(size) · \(size) × \(size)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.frame(minHeight: 52)
                        }.disabled(size == 18 && map.logicalNodes.contains(where: \.isStart)).accessibilityIdentifier("nodeSize-\(size)")
                    }
                }
                Section { Toggle("连续放置同类型", isOn: $continuousNodes); Text("选择后在地图上定位，先显示轮廓，确认后设置内容。开始节点只允许一个。") .font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("新增 LN").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } } }
        }
    }

    private func splitChooser(_ line: MapLine) -> some View {
        MapSplitEditor(line: line) { order in
            _ = try await model.execute("已拆分线路") {
                try await $0.splitLine(lineCode: line.code, version: line.version, cutBeforeOrder: order, session: $1)
            }
            selection = nil
        }
    }

    private func chooseTool(_ tool: MapTool) {
        guard !busy else { return }
        interaction.tool = tool; selection = nil; interaction.selectedID = nil
        area = nil; interaction.clearPreview()
    }
    private func select(_ item: MapSelection?) {
        guard !busy else { return }
        if let source = connectionSource, let item, case .logicalNode(let target) = item, source.code != target.code {
            sheet = .connection(source, target); connectionSource = nil; return
        }
        if let source = mergeSource, let item, case .line(let target) = item, source.code != target.code {
            sheet = .merge(source, target); mergeSource = nil; return
        }
        selection = item
        interaction.selectedID = item?.id
    }
    private func selectFromList(_ item: MapSelection) {
        // Close the list before opening a preview sheet for a second selected object.
        sheet = nil
        locate(item)
        if connectionSource != nil || mergeSource != nil {
            Task { try? await Task.sleep(nanoseconds: 300_000_000); select(item) }
        } else { select(item) }
    }
    private func editSelection(_ item: MapSelection) {
        switch item {
        case .line(let line):
            guard canEdit(line) else { localError = "只能编辑本人且未锁定的线路。"; return }
            run {
                let current = try await model.execute("已进入线路编辑", mutation: false, refresh: false) { try await $0.startDrawing(lineCode: line.code, session: $1) }
                draft = MapLineDraft(line: current); history = []; interaction.showCursor = true
                selection = nil; interaction.tool = .line
                if let last = current.nodes.last { interaction.locate(CGPoint(x: last.x, y: last.y)) }
            }
        case .logicalNode(let node): sheet = .node(node)
        case .cross(let cross): sheet = .cross(cross)
        }
    }
    private func beginNewLine() {
        draft = MapLineDraft(line: MapLine(code: "LOCALDRAFT", owner: model.session?.userName ?? "", isLocked: false, version: -1, nodes: []))
        history = []; interaction.showCursor = true; selection = nil
        interaction.locate(interaction.cursor, scale: max(4, interaction.currentScale))
    }
    private func mutateDraft(_ operation: (inout MapLineDraft) throws -> Void) {
        guard !busy, var value = draft else { return }
        do { let previous = value; try operation(&value); history.append(previous); draft = value; interaction.selectedPoint = nil }
        catch { localError = error.localizedDescription }
    }
    private func reloadDraft() {
        guard let value = draft, value.version >= 0 else { return }
        run {
            let current = try await model.execute("已重新加载线路", mutation: false, refresh: false) {
                try await $0.startDrawing(lineCode: value.lineCode, session: $1)
            }
            draft = MapLineDraft(line: current); history = []; interaction.selectedPoint = nil
            model.refresh()
        }
    }
    private func undoDraft() { if !busy, let previous = history.popLast() { draft = previous; interaction.selectedPoint = nil } }
    private func saveDraft() {
        guard let value = draft, value.validationMessage == nil else { return }
        run {
            var saving = value
            if saving.version < 0 {
                let created = try await model.execute("已建立线路，正在保存草稿", refresh: false) { try await $0.createLine(session: $1) }
                saving = MapLineDraft(line: created)
                saving.points = value.points.enumerated().map { MapLinePoint(lineCode: created.code, order: $0.offset, x: $0.element.x, y: $0.element.y) }
                draft = saving; history = []
            }
            let result = try await model.execute("线路已保存。可继续计算交点。") {
                try await $0.saveLine(lineCode: saving.lineCode, version: saving.version, nodes: saving.points, session: $1)
            }
            clearOperation(); selection = .line(result); interaction.selectedID = selection?.id
        }
    }
    private func moveDraftPoint() {
        guard let value = draft, let index = interaction.selectedPoint, value.points.indices.contains(index) else { return }
        let point = interaction.cursor
        if value.version < 0 { mutateDraft { try $0.movePoint(at: index, to: point) }; return }
        run {
            let proposal = try await model.execute("已找到合法位置", mutation: false, refresh: false) {
                try await $0.findNodePosition(lineCode: value.lineCode, version: value.version, nodes: value.points, nodeOrder: index,
                                             targetX: Double(point.x), targetY: Double(point.y), session: $1)
            }
            var changed = value; try changed.replacePoint(at: index, x: proposal.x, y: proposal.y)
            history.append(value); draft = changed; interaction.locate(CGPoint(x: proposal.x, y: proposal.y))
        }
    }
    private func tappedPoint(_ point: CGPoint) {
        guard !busy, let draft else { return }
        if let nearest = draft.points.min(by: { distance($0, point) < distance($1, point) }), distance(nearest, point) * interaction.currentScale <= 22 {
            interaction.selectedPoint = nearest.order
        }
    }
    private func beginConnection(_ node: MapLogicalNode) {
        selection = nil; connectionSource = node; interaction.tool = .node; interaction.showCursor = false
    }
    private func beginPaste() {
        guard !editing, let clipboard else { return }
        switch clipboard {
        case .line(let source): setPlacement(.pasteLine(source))
        case .node(let source): setPlacement(.copyNode(source))
        case .area(let source): setPlacement(.pasteArea(source))
        }
    }
    private func setPlacement(_ value: MapPlacement) {
        placement = value; selection = nil; interaction.selectedID = nil; interaction.showCursor = value.active
        switch value {
        case .newNode, .instance, .copyNode:
            interaction.locate(interaction.cursor, scale: max(6, interaction.currentScale))
        case .moveNode(let node): interaction.locate(CGPoint(x: node.x, y: node.y))
        case .moveArea(let selected): interaction.locate(areaCenter(selected))
        default: break
        }
        synchronizePreview()
    }
    private func confirmPlacement() {
        let cursor = interaction.cursor
        switch placement {
        case .none: break
        case .newNode(let size):
            let point = nodePoint(size)
            if continuousNodes, let template = lastNodeTemplate, template.sideLength == size, size != 18 {
                run { _ = try await model.execute("已新增 LN") { try await $0.createLogicalNode(x: Double(point.x), y: Double(point.y), sideLength: size, properties: template.properties, instanceParentCode: template.instanceParentCode, session: $1) } }
            } else { sheet = .newNode(size, point) }
        case .instance(let parent):
            let point = nodePoint(10)
            run { _ = try await model.execute("已新增实例") { try await $0.createLogicalNode(x: Double(point.x), y: Double(point.y), sideLength: 10, properties: MapNodeEditorRules.defaults(size: 10), instanceParentCode: parent.code, session: $1) }; if !continuousNodes { clearOperation() } }
        case .moveNode(let node):
            let point = nodePoint(node.sideLength)
            run { _ = try await model.execute("已移动 LN") { try await $0.moveLogicalNode(node: node, x: Double(point.x), y: Double(point.y), session: $1) }; clearOperation() }
        case .copyNode(let node):
            let point = nodePoint(node.sideLength)
            run { _ = try await model.execute("已粘贴 LN") { try await $0.createLogicalNode(x: Double(point.x), y: Double(point.y), sideLength: node.sideLength, properties: node.properties, session: $1) }; clearOperation() }
        case .pasteLine(let source):
            run { _ = try await model.execute("已粘贴线路") { try await $0.pasteLine(source: source, x: Int(cursor.x.rounded()), y: Int(cursor.y.rounded()), session: $1) }; clearOperation() }
        case .areaFirst: setPlacement(.areaSecond(CGPoint(x: cursor.x.rounded(), y: cursor.y.rounded())))
        case .areaSecond(let start):
            let bounds = areaBounds(start, cursor)
            guard bounds.isValid else { localError = "请选择不同的第二个角，让区域有宽度和高度。"; return }
            run { area = try await model.execute("已选中区域内的完整对象", mutation: false, refresh: false) { try await $0.selectMapArea(bounds: bounds, session: $1) }; placement = .none; interaction.showCursor = false; interaction.region = bounds }
        case .moveArea(let selected), .pasteArea(let selected):
            let center = areaCenter(selected), dx = Int((cursor.x - center.x).rounded()), dy = Int((cursor.y - center.y).rounded())
            let pasting: Bool = { if case .pasteArea = placement { return true }; return false }()
            run {
                if pasting {
                    let result = try await model.execute("已粘贴框选对象") { try await $0.pasteMapArea(selection: selected, deltaX: dx, deltaY: dy, session: $1) }
                    if !result.notes.isEmpty { localNotice = result.notes.joined(separator: "\n") }
                }
                else { _ = try await model.execute("已移动框选对象") { try await $0.moveMapArea(selection: selected, deltaX: dx, deltaY: dy, session: $1) } }
                clearOperation()
            }
        }
    }

    private func synchronizePreview() {
        if let draft {
            interaction.draftPoints = draft.points
            interaction.draftAnchor = draft.additionAnchor
            interaction.hiddenLineCode = draft.version < 0 ? nil : draft.lineCode
            return
        }
        interaction.preview = nil
        switch placement {
        case .newNode(let size): interaction.preview = nodePreview(size: size, properties: lastNodeTemplate?.properties ?? MapNodeEditorRules.defaults(size: size))
        case .instance: interaction.preview = nodePreview(size: 10, properties: MapNodeEditorRules.defaults(size: 10))
        case .moveNode(let node), .copyNode(let node): interaction.preview = nodePreview(size: node.sideLength, properties: node.properties)
        case .pasteLine(let source):
            if let first = source.nodes.first {
                let line = MapLine(code: source.code, owner: "", isLocked: source.isLocked, version: source.version, nodes: source.nodes, properties: source.properties)
                interaction.preview = MapPreviewTransform.shifted(MapSnapshot(lines: [line]), dx: Int(interaction.cursor.x.rounded()) - first.x, dy: Int(interaction.cursor.y.rounded()) - first.y)
            }
        case .areaSecond(let start): interaction.region = areaBounds(start, interaction.cursor)
        case .moveArea(let selected), .pasteArea(let selected):
            let center = areaCenter(selected)
            let dx = Int((interaction.cursor.x - center.x).rounded()), dy = Int((interaction.cursor.y - center.y).rounded())
            interaction.preview = MapPreviewTransform.shifted(selected.snapshot, dx: dx, dy: dy)
            interaction.region = MapAreaBounds(left: selected.bounds.left + Double(dx), bottom: selected.bounds.bottom + Double(dy), right: selected.bounds.right + Double(dx), top: selected.bounds.top + Double(dy))
        default: break
        }
    }
    private func nodePreview(size: Int, properties: MapNodeProperties) -> MapSnapshot {
        let point = nodePoint(size)
        return MapSnapshot(logicalNodes: [MapLogicalNode(code: "LOCALDRAFT", owner: "", version: 0,
             x: Double(point.x), y: Double(point.y), sideLength: size, properties: properties)])
    }
    private func nodePoint(_ size: Int) -> CGPoint {
        CGPoint(x: min(499_999.5, max(0.5, floor(interaction.cursor.x) + 0.5)),
                y: min(499_999.5, max(0.5, floor(interaction.cursor.y) + 0.5)))
    }
    private func clearOperation() {
        draft = nil; history = []; placement = .none; area = nil; connectionSource = nil; mergeSource = nil
        selection = nil; interaction.selectedID = nil; interaction.clearPreview()
    }
    private func cancelOperation() {
        if let draft, !draft.points.isEmpty { confirm("放弃未保存的线路草稿？") { clearOperation() } }
        else { clearOperation() }
    }
    private func locate(_ item: MapSelection) {
        switch item {
        case .logicalNode(let node): interaction.locate(CGPoint(x: node.x, y: node.y), scale: max(6, interaction.currentScale))
        case .cross(let cross): interaction.locate(CGPoint(x: cross.x, y: cross.y), scale: max(8, interaction.currentScale))
        case .line(let line):
            guard let minX = line.nodes.map(\.x).min(), let maxX = line.nodes.map(\.x).max(),
                  let minY = line.nodes.map(\.y).min(), let maxY = line.nodes.map(\.y).max() else { return }
            let width = CGFloat(max(20, max(maxX - minX, maxY - minY)))
            interaction.locate(CGPoint(x: Double(minX + maxX) / 2, y: Double(minY + maxY) / 2), scale: min(16, 240 / width))
        }
    }
    private func refreshSelection() {
        guard let selected = selection else { return }
        switch selected {
        case .line(let old): selection = map.lines.first(where: { $0.code == old.code }).map(MapSelection.line)
        case .logicalNode(let old): selection = map.logicalNodes.first(where: { $0.code == old.code }).map(MapSelection.logicalNode)
        case .cross(let old): selection = map.crosses.first(where: { $0.key == old.key }).map(MapSelection.cross)
        }
        interaction.selectedID = selection?.id
    }
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }; running = true; localNotice = nil
        Task { defer { running = false }; do { try await work() } catch { localError = error.localizedDescription } }
    }
    private func confirm(_ title: String, action: @escaping () -> Void) {
        confirmationTitle = title; confirmationAction = action; showingConfirmation = true
    }
    private func canEdit(_ line: MapLine) -> Bool { !line.isLocked && line.owner == model.session?.userName }
    private func canEdit(_ node: MapLogicalNode) -> Bool { node.canEdit ?? (node.owner == model.session?.userName) }
    private func areaCenter(_ selection: MapAreaSelection) -> CGPoint {
        CGPoint(x: (selection.bounds.left + selection.bounds.right) / 2, y: (selection.bounds.bottom + selection.bounds.top) / 2)
    }
    private func areaBounds(_ a: CGPoint, _ b: CGPoint) -> MapAreaBounds {
        MapAreaBounds(left: Double(min(a.x, b.x).rounded()), bottom: Double(min(a.y, b.y).rounded()),
                      right: Double(max(a.x, b.x).rounded()), top: Double(max(a.y, b.y).rounded()))
    }
    private func distance(_ point: MapLinePoint, _ other: CGPoint) -> CGFloat { hypot(CGFloat(point.x) - other.x, CGFloat(point.y) - other.y) }
    private func toolID(_ tool: MapTool) -> String {
        switch tool { case .browse: return "browse"; case .line: return "line"; case .cross: return "cross"; case .node: return "node"; case .area: return "area" }
    }
    private func nodeTypeTitle(_ size: Int) -> String {
        switch size { case 4: return "是 / 否分支"; case 6: return "命题"; case 8: return "关系 / 非 NOT"; case 10: return "实例"; case 12: return "类 / 事实"; default: return "开始" }
    }
    private func selectionTitle(_ item: MapSelection) -> String {
        switch item {
        case .line(let line): return "线路 · " + (line.properties.roadName.isEmpty ? line.code : line.properties.roadName)
        case .logicalNode(let node): return "LN\(node.sideLength) · \(node.properties.value)"
        case .cross(let cross): return "Cross · (\(cross.key.position.x2 / 2), \(cross.key.position.y2 / 2))"
        }
    }
    private var toolHint: String {
        switch interaction.tool {
        case .line: return "点选线路后编辑，或新建一条线路"
        case .node: return "点选 LN 编辑，或选择类型后落点"
        case .cross: return "点选交点，直接设置换路方向"
        case .area: return "选择两个角，框住完整的线路和 LN"
        default: return "拖动平移 · 双指缩放 · 点选对象"
        }
    }
    private var editingHint: String {
        if let draft { return "\(draft.addFromStart ? "前端" : "末端")加点 · 已有 \(draft.points.count) 个点。移动地图对准准星，点“加点”。" }
        if connectionSource != nil { return "请选择目标 LN；点地图或从列表选择。" }
        if mergeSource != nil { return "请选择第二条线路，随后预览合并方案。" }
        switch placement {
        case .areaFirst: return "第 1 步：把准星移到区域的第一个角。"
        case .areaSecond: return "第 2 步：选择对角，预览框选范围。"
        case .moveArea, .pasteArea: return "移动地图调整整组位置，预览后确认。"
        case .moveNode: return "移动地图调整 LN 位置，确认后保存。"
        case .pasteLine, .copyNode: return "选择粘贴位置，预览后确认。"
        default: return "选择 LN 落点，中心自动吸附整数＋0.5。"
        }
    }
    private var placementButton: String {
        switch placement { case .areaFirst: return "确定第一个角"; case .areaSecond: return "完成框选"; default: return "确认落点" }
    }
}
