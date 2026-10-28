import SwiftUI

@MainActor
struct MapLinePropertiesEditor: View {
    let line: MapLine
    let onSave: (MapLineProperties) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var roadName: String
    @State private var roadDetail: String
    @State private var speed: String
    @State private var twoWay: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(line: MapLine, onSave: @escaping (MapLineProperties) async throws -> Void) {
        self.line = line
        self.onSave = onSave
        _roadName = State(initialValue: line.properties.roadName)
        _roadDetail = State(initialValue: line.properties.roadDetail)
        _speed = State(initialValue: String(line.properties.speed))
        _twoWay = State(initialValue: line.properties.passInOpposeDirection == 1)
    }

    private var properties: MapLineProperties? {
        guard roadName.utf16.count <= 15, roadDetail.utf16.count <= 127,
              let speed = Int(speed.trimmingCharacters(in: .whitespacesAndNewlines)),
              (5...500).contains(speed) else { return nil }
        return MapLineProperties(roadName: roadName, roadDetail: roadDetail, speed: speed,
                                 passInDirection: 1, passInOpposeDirection: twoWay ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("线路资料") {
                    TextField("线路名称（最多 15 字符）", text: $roadName)
                        .accessibilityIdentifier("lineName")
                    TextField("说明（最多 127 字符）", text: $roadDetail, axis: .vertical)
                        .lineLimit(3...6).accessibilityIdentifier("lineDetail")
                }
                Section("通行") {
                    Toggle("允许双向通行", isOn: $twoWay)
                        .accessibilityIdentifier("lineTwoWay")
                    HStack {
                        Text("速度")
                        Spacer()
                        TextField("5…500", text: $speed)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100).accessibilityIdentifier("lineSpeed")
                    }
                    Text(twoWay ? "两个方向均可通行，按相反方向显示成对箭头。" : "沿节点顺序单向通行。需要改变方向时，使用线路菜单中的“反转方向”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if properties == nil {
                    Section {
                        Label("名称最多 15 字符、说明最多 127 字符；速度为 5…500 的整数。", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if line.isLocked {
                    Section { Text("线路已锁定，请先解锁后再修改属性。").foregroundStyle(.orange) }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                        .accessibilityIdentifier("linePropertiesError")
                }
                Section("身份") {
                    LabeledContent("编码", value: line.code)
                    LabeledContent("负责人", value: line.owner)
                }
            }
            .disabled(isSaving)
            .navigationTitle("线路属性").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") { save() }
                        .disabled(isSaving || line.isLocked || properties == nil)
                        .accessibilityIdentifier("saveLineProperties")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() {
        guard !isSaving, !line.isLocked, let properties else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(properties)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }
}

@MainActor
struct MapLinePointList: View {
    @Binding var draft: MapLineDraft
    let onChoosePoint: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("添加位置", selection: $draft.addFromStart) {
                        Text("末端加点").tag(false)
                        Text("前端加点").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("lineAdditionEnd")
                    Text("点选节点后回到地图调整位置。向左轻扫可删除；最后点击“校验保存”提交整条线路。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("节点 · \(draft.points.count)") {
                    ForEach(Array(draft.points.enumerated()), id: \.element.id) { index, point in
                        Button {
                            onChoosePoint(index)
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                Text("\(point.x), \(point.y)").font(.body.monospacedDigit())
                                Spacer()
                                if index == 0 { Text("起点").font(.caption).foregroundStyle(.secondary) }
                                else if index + 1 == draft.points.count { Text("终点").font(.caption).foregroundStyle(.secondary) }
                                Image(systemName: "scope").foregroundStyle(.tint)
                            }.frame(minHeight: 44)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("linePoint-\(index)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { remove(index) }
                                .accessibilityIdentifier("removeLinePoint-\(index)")
                        }
                    }
                    if draft.points.isEmpty {
                        Text("尚未添加节点，请回到地图点选位置。").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("线路节点").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert("节点操作未完成", isPresented: $showError) { Button("好", role: .cancel) {} }
                message: { Text(errorMessage) }
        }
    }

    private func remove(_ index: Int) {
        do { try draft.removePoint(at: index) }
        catch { errorMessage = error.localizedDescription; showError = true }
    }
}
