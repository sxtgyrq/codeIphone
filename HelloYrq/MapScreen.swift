import SwiftUI

struct MapNodeList: View {
    let nodes: [MapLogicalNode]
    var onChoose: ((MapLogicalNode) -> Void)? = nil
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
                Button {
                    if let onChoose { onChoose(node); dismiss() }
                    else { selection = .logicalNode(node) }
                } label: {
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
