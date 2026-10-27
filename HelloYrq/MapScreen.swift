import SwiftUI

@MainActor
struct MapScreen: View {
    @ObservedObject var model: MapViewModel
    @State private var showArrows = true
    @State private var showLabels = true
    @State private var showCrosses = true
    @State private var fitRequest = 0
    @State private var selection: MapSelection?
    @State private var showNodes = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                ZStack {
                    if let map = model.snapshot {
                        MapCanvasView(snapshot: map, showArrows: showArrows, showLabels: showLabels,
                                      showCrosses: showCrosses, fitRequest: fitRequest,
                                      onSelect: { selection = $0 })
                            .accessibilityIdentifier("logicMap")
                        if map.lines.allSatisfy({ $0.nodes.isEmpty }) && map.logicalNodes.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "square.dashed").font(.largeTitle)
                                Text("地图暂时为空").font(.headline)
                                Text("在电脑版保存地图后，点击刷新。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        }
                    } else {
                        Color(uiColor: .systemGroupedBackground)
                        VStack(spacing: 16) {
                            if model.isWorking {
                                ProgressView()
                                Text("正在读取逻辑地图…")
                            } else {
                                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                                Text("地图尚未加载").font(.headline)
                                Button("重新加载") { model.refresh() }.buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("retryMap")
                            }
                        }
                    }
                    if model.isWorking && model.snapshot != nil {
                        VStack { HStack { Spacer(); ProgressView().padding(12).background(.regularMaterial, in: Capsule()) }; Spacer() }.padding()
                            .allowsHitTesting(false)
                    }
                }
                controls
            }
            .navigationTitle("逻辑地图").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Text(model.session?.userName ?? "")
                        Text(model.serverAddress)
                        Button("退出登录", role: .destructive) { model.logout() }
                            .accessibilityIdentifier("logoutButton")
                    } label: { Label("账号", systemImage: "person.crop.circle") }
                    .accessibilityIdentifier("accountMenu")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNodes = true } label: { Label("节点列表", systemImage: "list.bullet") }
                        .disabled(model.snapshot == nil).accessibilityIdentifier("nodesButton")
                }
            }
            .sheet(item: $selection) { item in
                MapObjectDetails(selection: item).presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showNodes) {
                MapNodeList(nodes: model.snapshot?.logicalNodes ?? [])
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let map = model.snapshot {
                HStack {
                    Text("线路 \(map.lines.filter { !$0.nodes.isEmpty }.count) · LN \(map.logicalNodes.count) · Cross \(map.crosses.count)")
                        .font(.caption).accessibilityIdentifier("mapCounts")
                    Spacer()
                    if let time = model.lastRefresh {
                        Text(time, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).accessibilityIdentifier("mapError")
                if model.snapshot != nil { Text("当前显示上次成功加载的地图。").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("单指拖动 · 双指缩放 · 点选查看详情")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var controls: some View {
        HStack {
            Button { fitRequest += 1 } label: { Label("查看全部", systemImage: "arrow.up.left.and.arrow.down.right") }
                .disabled(model.snapshot == nil).accessibilityIdentifier("fitMap")
            Spacer()
            Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(model.isWorking).accessibilityIdentifier("refreshMap")
            Spacer()
            Menu {
                Toggle("线路箭头", isOn: $showArrows)
                Toggle("LN 标签", isOn: $showLabels)
                Toggle("Cross 交点", isOn: $showCrosses)
            } label: { Label("显示", systemImage: "slider.horizontal.3") }
            .accessibilityIdentifier("displayMenu")
        }
        .font(.subheadline).padding(.horizontal, 18).frame(minHeight: 54)
        .background(.regularMaterial)
    }
}

struct MapNodeList: View {
    let nodes: [MapLogicalNode]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: MapSelection?

    private var filtered: [MapLogicalNode] {
        nodes.filter { query.isEmpty || $0.properties.value.localizedCaseInsensitiveContains(query)
            || $0.properties.logicLanguage.localizedCaseInsensitiveContains(query)
            || $0.code.localizedCaseInsensitiveContains(query) }
            .sorted { $0.code < $1.code }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { node in
                Button { selection = .logicalNode(node) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("LN\(node.sideLength)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(node.properties.value.isEmpty ? node.code : node.properties.value).font(.headline)
                        }
                        if !node.properties.logicLanguage.isEmpty {
                            Text(node.properties.logicLanguage).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }.foregroundStyle(.primary)
            }
            .searchable(text: $query, prompt: "搜索值、逻辑语言或编码")
            .navigationTitle("逻辑节点 · \(nodes.count)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $selection) { MapObjectDetails(selection: $0).presentationDetents([.medium, .large]) }
            .accessibilityIdentifier("nodeList")
        }
    }
}

struct MapObjectDetails: View {
    let selection: MapSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch selection {
                case .logicalNode(let node):
                    Section("LN\(node.sideLength)") {
                        detail("值", node.properties.value)
                        detail("逻辑语言", node.properties.logicLanguage)
                        detail("说明", node.properties.info)
                    }
                    Section("位置与资料") {
                        detail("坐标", "\(coordinate(node.x)), \(coordinate(node.y))")
                        detail("编码", node.code)
                        detail("负责人", node.owner)
                        detail("关联线路位置", String(node.positions.count))
                    }
                case .line(let line):
                    Section("线路") {
                        detail("名称", line.properties.roadName)
                        detail("说明", line.properties.roadDetail)
                        detail("方向", line.properties.passInOpposeDirection == 1 ? "双向" : "按节点顺序单向")
                        detail("速度", String(line.properties.speed))
                        detail("节点数", String(line.nodes.count))
                        detail("锁定", line.isLocked ? "已锁定" : "未锁定")
                        detail("编码", line.code)
                        detail("负责人", line.owner)
                    }
                case .cross(let cross):
                    Section("Cross 交点") {
                        detail("坐标", "\(coordinate(cross.x)), \(coordinate(cross.y))")
                        detail("换路方式", crossState(cross.state))
                        detail("Road1", cross.key.roadCode1)
                        detail("Road2", cross.key.roadCode2)
                    }
                }
            }
            .textSelection(.enabled)
            .navigationTitle("对象详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .accessibilityIdentifier("objectDetails")
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.body)
        }.padding(.vertical, 3)
    }

    private func coordinate(_ value: Double) -> String { value.formatted(.number.grouping(.never).precision(.fractionLength(0...1))) }
    private func crossState(_ state: Int) -> String {
        switch state {
        case -1: return "不连通"
        case 0: return "未设置"
        case 1: return "双向换路"
        case 2: return "Road1 → Road2"
        case 3: return "Road2 → Road1"
        default: return "未知状态"
        }
    }
}
