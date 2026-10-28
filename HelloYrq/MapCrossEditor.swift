import SwiftUI

/// Every row represents a distinct road pair at the selected integer position.
/// Choosing a row on iPhone replaces WPF's Tab-to-cycle gesture.
@MainActor
struct MapCrossEditor: View {
    let cross: MapCross
    let relatedCrosses: [MapCross]
    let lines: [MapLine]
    let onSave: (MapCross, Int) async throws -> Void
    let onLocateLine: ((MapLine) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKey: MapCrossKey
    @State private var state: Int
    @State private var busy = false
    @State private var error: String?

    init(cross: MapCross, relatedCrosses: [MapCross], lines: [MapLine],
         onSave: @escaping (MapCross, Int) async throws -> Void,
         onLocateLine: ((MapLine) -> Void)? = nil) {
        self.cross = cross
        self.relatedCrosses = relatedCrosses
        self.lines = lines
        self.onSave = onSave
        self.onLocateLine = onLocateLine
        self._selectedKey = State(initialValue: cross.key)
        self._state = State(initialValue: cross.state)
    }

    private var pairs: [MapCross] {
        var byKey = Dictionary(relatedCrosses.filter { $0.key.position == cross.key.position }.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        if byKey[cross.key] == nil { byKey[cross.key] = cross }
        return byKey.values.sorted { $0.key.roadCode1 + $0.key.roadCode2 < $1.key.roadCode1 + $1.key.roadCode2 }
    }
    private var selected: MapCross { pairs.first { $0.key == selectedKey } ?? cross }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("坐标", value: "\(selected.key.position.x2 / 2), \(selected.key.position.y2 / 2)")
                    Text("此位置有 \(pairs.count) 对线路关系。选择需要设置的那一对，不会修改其他关系。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("选择线路关系") {
                    ForEach(pairs) { pair in
                        Button { select(pair) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedKey == pair.key ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedKey == pair.key ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(roadName(pair.key.roadCode1) + " / " + roadName(pair.key.roadCode2)).foregroundStyle(.primary)
                                    Text("\(pair.key.roadCode1) · \(pair.key.roadCode2)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(stateTitle(pair.state, cross: pair)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("crossPair-\(pair.key.roadCode1)-\(pair.key.roadCode2)")
                    }
                }
                Section {
                    stateButton(1, icon: "arrow.left.arrow.right", title: "双向连通", subtitle: "两条线路之间可以互相换路")
                    stateButton(-1, icon: "xmark", title: "不连通", subtitle: "经过此处时保持原线路")
                    stateButton(2, icon: "arrow.right", title: roadName(selected.key.roadCode1) + " → " + roadName(selected.key.roadCode2),
                                subtitle: "单向：\(selected.key.roadCode1) → \(selected.key.roadCode2)")
                    stateButton(3, icon: "arrow.left", title: roadName(selected.key.roadCode2) + " → " + roadName(selected.key.roadCode1),
                                subtitle: "单向：\(selected.key.roadCode2) → \(selected.key.roadCode1)")
                    stateButton(0, icon: "questionmark", title: "重置为未设置", subtitle: "清除此交点的通行标记")
                } header: { Text("换路方式") } footer: {
                    Text("单向换路直接选择入口 → 出口，无需先记忆出口线路。LN 范围内的 Cross 必须保持不连通。")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("crossEditorError") }
                }
                if onLocateLine != nil {
                    Section("查看线路") {
                        locateButton(selected.key.roadCode1)
                        locateButton(selected.key.roadCode2)
                    }
                }
            }
            .disabled(busy)
            .navigationTitle("Cross 交点").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if busy { ProgressView() } else { Text("保存") }
                    }.disabled(busy).accessibilityIdentifier("saveCrossState")
                }
            }
            .interactiveDismissDisabled(busy)
            .accessibilityIdentifier("crossEditor")
        }
    }

    private func stateButton(_ newState: Int, icon: String, title: String, subtitle: String) -> some View {
        Button { state = newState; error = nil } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if state == newState { Image(systemName: "checkmark.circle.fill") }
            }.frame(minHeight: 44, alignment: .leading)
        }.accessibilityIdentifier("crossState\(newState)")
    }

    @ViewBuilder private func locateButton(_ code: String) -> some View {
        if let line = lines.first(where: { $0.code == code }), let onLocateLine {
            Button { onLocateLine(line); dismiss() } label: {
                Label(roadName(code), systemImage: "location").frame(minHeight: 44, alignment: .leading)
            }
        }
    }
    private func roadName(_ code: String) -> String {
        let name = lines.first { $0.code == code }?.properties.roadName ?? ""
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? code : name
    }
    private func stateTitle(_ value: Int, cross: MapCross) -> String {
        switch value {
        case -1: return "不连通"
        case 0: return "未设置"
        case 1: return "双向连通"
        case 2: return cross.key.roadCode1 + " → " + cross.key.roadCode2
        default: return cross.key.roadCode2 + " → " + cross.key.roadCode1
        }
    }
    private func select(_ pair: MapCross) {
        guard !busy else { return }
        selectedKey = pair.key; state = pair.state; error = nil
    }
    private func save() {
        guard !busy else { return }
        let savedCross = selected, savedState = state
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await onSave(savedCross, savedState); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
