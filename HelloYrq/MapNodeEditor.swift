import SwiftUI
import Foundation

struct MapNodeEditorDraft {
    let x: Double
    let y: Double
    let sideLength: Int
    let properties: MapNodeProperties
    // Only the automatic LN12 -> LN10 creation flow sends this value. The
    // Server replaces the draft with parent(id=newNodeCode) in one transaction.
    var instanceParentCode: String? = nil
}

/// A touch form for the same LN operations and value rules as the WPF editor.
/// The authenticated Server remains authoritative for permissions, geometry,
/// uniqueness, references and optimistic version checks.
@MainActor
struct MapNodeEditor: View {
    let node: MapLogicalNode?
    let userName: String
    let allNodes: [MapLogicalNode]
    let snapshot: MapSnapshot
    let onSave: (MapNodeEditorDraft) async throws -> Void
    let onDelete: ((MapLogicalNode) async throws -> Void)?
    let onMove: ((MapLogicalNode) -> Void)?
    let onLocate: ((MapLogicalNode) -> Void)?
    let onCopy: ((MapLogicalNode) -> Void)?
    let onConnect: ((MapLogicalNode) -> Void)?
    let onCreateInstance: ((MapLogicalNode) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var x: String
    @State private var y: String
    @State private var sideLength: Int
    @State private var value: String
    @State private var logic: String
    @State private var info: String
    @State private var operandKind: String
    @State private var followsClassValue: Bool
    @State private var automaticInstance = false
    @State private var instanceParentCode = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var showBranchPicker = false
    @State private var previewLocation: MapNodePreviewLocation?
    @State private var conflictLocation: MapNodePreviewLocation?

    init(node: MapLogicalNode? = nil, userName: String, allNodes: [MapLogicalNode], snapshot: MapSnapshot, center: CGPoint,
         sideLength: Int = 6, onSave: @escaping (MapNodeEditorDraft) async throws -> Void,
         onDelete: ((MapLogicalNode) async throws -> Void)? = nil,
         onMove: ((MapLogicalNode) -> Void)? = nil,
         onLocate: ((MapLogicalNode) -> Void)? = nil,
         onCopy: ((MapLogicalNode) -> Void)? = nil,
         onConnect: ((MapLogicalNode) -> Void)? = nil,
         onCreateInstance: ((MapLogicalNode) -> Void)? = nil) {
        self.node = node
        self.userName = userName
        self.allNodes = allNodes
        self.snapshot = snapshot
        self.onSave = onSave
        self.onDelete = onDelete
        self.onMove = onMove
        self.onLocate = onLocate
        self.onCopy = onCopy
        self.onConnect = onConnect
        self.onCreateInstance = onCreateInstance
        let size = node?.sideLength ?? sideLength
        let properties = node?.properties ?? MapNodeEditorRules.defaults(size: size)
        let draftValue = MapNodeEditorRules.singleLine(properties.value)
        let draftLogic = MapNodeEditorRules.singleLine(properties.logicLanguage)
        self._x = State(initialValue: Self.coordinate(node?.x ?? Double(center.x)))
        self._y = State(initialValue: Self.coordinate(node?.y ?? Double(center.y)))
        self._sideLength = State(initialValue: size)
        self._value = State(initialValue: draftValue)
        self._logic = State(initialValue: size == 8 ? MapNodeEditorRules.relationLogic(draftValue) :
                            size == 10 ? MapNodeEditorRules.instanceExpression(draftValue) :
                            size == 12 && draftLogic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? MapNodeEditorRules.uppercase(draftValue) : draftLogic)
        self._info = State(initialValue: properties.info)
        self._operandKind = State(initialValue: properties.operandKind)
        self._followsClassValue = State(initialValue: size == 12 && (node == nil || draftLogic.isEmpty))
    }

    private var canEdit: Bool { node?.canEdit ?? (node == nil || node?.owner == userName || userName == "admin") }
    private var automaticParent: MapLogicalNode? {
        allNodes.first { $0.code == instanceParentCode && MapNodeEditorRules.canInstantiate($0) }
    }
    private var isAutomaticInstance: Bool { node == nil && sideLength == 10 && automaticInstance }
    private var classNodes: [MapLogicalNode] {
        allNodes.filter(MapNodeEditorRules.canInstantiate).sorted { $0.properties.value < $1.properties.value }
    }
    private var submittedProperties: MapNodeProperties {
        let normalizedValue = sideLength == 10 ? MapNodeEditorRules.normalizeInstance(value) :
            sideLength == 12 ? MapNodeEditorRules.uppercase(value) : value
        let normalizedLogic = sideLength == 8 ? MapNodeEditorRules.relationLogic(normalizedValue) :
            sideLength == 10 ? MapNodeEditorRules.instanceExpression(normalizedValue) :
            sideLength == 6 ? MapNodeEditorRules.operandLogic(logic, kind: operandKind) : logic
        return MapNodeProperties(value: normalizedValue, info: info, logicLanguage: normalizedLogic,
                                 operandKind: sideLength == 6 ? operandKind : "Custom")
    }
    private var changedProperties: Bool { node.map { submittedProperties != $0.properties } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if let node {
                    Section {
                        LabeledContent("编码", value: node.code)
                        LabeledContent("负责人", value: node.owner)
                        if !canEdit { Text("当前账号只能查看此节点。").foregroundStyle(.secondary) }
                        if MapNodeEditorRules.singleLine(node.properties.value) != node.properties.value ||
                            MapNodeEditorRules.singleLine(node.properties.logicLanguage) != node.properties.logicLanguage {
                            Text("原值或逻辑语言含换行，编辑草稿已用空格替换。请核对后保存。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                geometrySection
                metadataSection
                navigationSection
                if let node { positionsSection(node) }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("nodeEditorError")
                        if let conflictLocation {
                            Button { previewLocation = conflictLocation } label: {
                                Label("查看冲突 LN 的位置", systemImage: "map")
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("previewNodeConflict")
                        }
                    }
                }
                if let node { actionsSection(node) }
            }
            .disabled(busy)
            .navigationTitle(node == nil ? "新增 LN" : "编辑 LN\(sideLength)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if busy { ProgressView() } else { Text("保存") }
                    }.disabled(busy || !canEdit).accessibilityIdentifier("saveLogicalNode")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("删除这个逻辑节点？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除节点", role: .destructive) { delete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除 LN\(sideLength) \(node?.code ?? "")。相关引用由服务器按现有规则处理。")
            }
            .sheet(isPresented: $showBranchPicker) {
                MapNodeSourcePicker(nodes: allNodes.filter { $0.sideLength == 6 }) { source in
                    logic = value == "True" ? source.properties.logicLanguage : "¬" + source.properties.logicLanguage
                }
            }
            .sheet(item: $previewLocation) { location in
                MapNodeLocationPreview(snapshot: snapshot, location: location)
                    .presentationDetents([.large])
            }
            .accessibilityIdentifier("logicalNodeEditor")
        }
    }

    private var geometrySection: some View {
        Section {
            Picker("类型", selection: Binding(get: { sideLength }, set: changeSize)) {
                ForEach([4, 6, 8, 10, 12, 18], id: \.self) { size in
                    Text(MapNodeEditorRules.sizeLabel(size)).tag(size)
                }
            }.disabled(node != nil || !canEdit).accessibilityIdentifier("logicalNodeSize")
            HStack {
                coordinateField("中心 X", text: $x, identifier: "logicalNodeX")
                coordinateField("中心 Y", text: $y, identifier: "logicalNodeY")
            }.disabled(node != nil || !canEdit)
            if node != nil {
                Text("如需调整位置，请点下方“在地图上移动”；已保存节点的尺寸不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("位置与类型") } footer: {
            Text("中心为整数＋0.5。LN 不能重叠或接触，范围内不能有线路节点；Cross 必须不连通。横、竖线可以穿过，斜线只能经过顶点。")
        }
    }

    private func coordinateField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).keyboardType(.decimalPad).textInputAutocapitalization(.never)
                .autocorrectionDisabled().accessibilityIdentifier(identifier)
        }
    }

    private var metadataSection: some View {
        Section {
            if sideLength == 4 {
                Picker("分支", selection: Binding(get: { value }, set: changeBranch)) {
                    Text("True · 是").tag("True")
                    Text("False · 否").tag("False")
                }.pickerStyle(.segmented).accessibilityIdentifier("logicalNodeBranch")
            } else if sideLength == 8 {
                Picker("关系", selection: Binding(get: { value }, set: { value = $0; logic = MapNodeEditorRules.relationLogic($0) })) {
                    ForEach(MapNodeEditorRules.relations, id: \.symbol) { relation in
                        Text("\(relation.symbol) · \(relation.name)").tag(relation.symbol)
                    }
                }.accessibilityIdentifier("logicalNodeRelation")
            } else {
                if sideLength == 10 && node == nil {
                    Toggle("按所属类自动生成实例", isOn: $automaticInstance)
                    if automaticInstance {
                        Picker("所属 LN12", selection: $instanceParentCode) {
                            Text("请选择所属类").tag("")
                            ForEach(classNodes) { parent in Text(parent.properties.value).tag(parent.code) }
                        }.accessibilityIdentifier("instanceParent")
                        Text("保存时生成唯一实例标识。需要填写属性或别名时，可关闭自动生成并输入实例表达式。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !isAutomaticInstance {
                    TextField(sideLength == 10 ? "例如 human(name=Alice) a" : "值", text: Binding(get: { value }, set: changeValue))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("logicalNodeValue")
                    if sideLength == 10 && !classNodes.isEmpty {
                        Menu("选择所属类") {
                            ForEach(classNodes) { parent in
                                Button(parent.properties.value) {
                                    let suffix = value.firstIndex(of: "(").map { String(value[$0...]) } ?? "()"
                                    changeValue(MapNodeEditorRules.lowercase(parent.properties.value) + suffix)
                                }
                            }
                        }
                    }
                }
            }
            if sideLength == 6 {
                Picker("作用对象", selection: Binding(get: { operandKind }, set: { operandKind = $0; logic = MapNodeEditorRules.operandLogic(logic, kind: $0) })) {
                    Text("自定义 · 保留原文").tag("Custom")
                    Text("类 · 自动大写").tag("Class")
                    Text("实例 · 自动小写").tag("Instance")
                }.accessibilityIdentifier("logicalNodeOperand")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("逻辑语言").font(.caption).foregroundStyle(.secondary)
                if sideLength == 8 || sideLength == 10 {
                    Text(isAutomaticInstance ? "保存时按所属类自动生成" : submittedProperties.logicLanguage)
                        .textSelection(.enabled).accessibilityIdentifier("logicalNodeGeneratedLogic")
                } else {
                    TextField("逻辑语言", text: Binding(get: { logic }, set: {
                        followsClassValue = false
                        logic = sideLength == 6 ? MapNodeEditorRules.operandLogic($0, kind: operandKind) : $0
                    }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("logicalNodeLogic")
                }
            }
            if sideLength == 4 {
                HStack {
                    Button("选择命题 LN6") { showBranchPicker = true }
                    Spacer()
                    Button("清空") { logic = "" }.disabled(logic.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("说明").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $info).frame(minHeight: 88).accessibilityIdentifier("logicalNodeInfo")
            }
            Text(MapNodeEditorRules.hint(size: sideLength)).font(.caption).foregroundStyle(.secondary)
        } header: { Text("节点内容") }
        .disabled(!canEdit)
    }

    @ViewBuilder private var navigationSection: some View {
        Group {
            if sideLength == 4, let sourceLogic = MapNodeEditorRules.branchSource(value: value, logic: logic) {
                let sources = allNodes.filter { $0.sideLength == 6 && $0.properties.logicLanguage == sourceLogic }
                Section("关联命题") {
                    if sources.count == 1 { locateButton(sources[0], title: "查看关联 LN6") }
                    else { Text("当前地图中没有唯一匹配的 LN6，请刷新或重新选择命题。").foregroundStyle(.secondary) }
                }
            }
            if sideLength == 10 {
                let parents = allNodes.filter { $0.sideLength == 12 && $0.properties.value == MapNodeEditorRules.instanceParent(value) }
                if let parent = isAutomaticInstance ? automaticParent : parents.first {
                    Section("所属类") { locateButton(parent, title: "查看所属 LN12") }
                }
            }
            if let node, sideLength == 6 {
                let branches = allNodes.filter { $0.sideLength == 4 && MapNodeEditorRules.branchSource(value: $0.properties.value, logic: $0.properties.logicLanguage) == node.properties.logicLanguage }
                    .sorted { ($0.properties.value == "True" ? "0" : "1") + $0.code < ($1.properties.value == "True" ? "0" : "1") + $1.code }
                Section("引用它的 LN4 · \(branches.count)") {
                    if branches.isEmpty { Text("暂无分支引用。").foregroundStyle(.secondary) }
                    ForEach(branches) { branch in locateButton(branch, title: "\(branch.properties.value) · \(branch.code)") }
                }
            }
            if let node, sideLength == 12 {
                let instances = allNodes.filter { $0.sideLength == 10 && MapNodeEditorRules.instanceParent($0.properties.value) == node.properties.value }
                Section("关联实例 · \(instances.count)") {
                    if instances.isEmpty { Text("暂无 LN10 实例。").foregroundStyle(.secondary) }
                    ForEach(instances) { child in locateButton(child, title: child.properties.value) }
                }
            }
        }
    }

    private func locateButton(_ target: MapLogicalNode, title: String) -> some View {
        Button { previewLocation = MapNodePreviewLocation(node: target) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: "map")
                Text("X \(Self.coordinate(target.x)) · Y \(Self.coordinate(target.y))").font(.caption).foregroundStyle(.secondary)
            }.frame(minHeight: 44, alignment: .leading)
        }.accessibilityIdentifier("previewNode-\(target.code)")
    }

    private func positionsSection(_ node: MapLogicalNode) -> some View {
        Section("穿过节点的线段 · \(node.positions.count)") {
            if node.positions.isEmpty { Text("暂无关联线路位置。").foregroundStyle(.secondary) }
            ForEach(node.positions) { position in
                VStack(alignment: .leading, spacing: 5) {
                    Text(position.roadCode).font(.body.monospaced())
                    Text("线段 \(position.roadOrder) · X \(Self.coordinate(position.x)) · Y \(Self.coordinate(position.y))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionsSection(_ node: MapLogicalNode) -> some View {
        Section {
            if let onMove, canEdit {
                Button { navigate(node, using: onMove) } label: { Label("在地图上移动", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                    .accessibilityIdentifier("moveLogicalNode")
            }
            if let onCopy, node.sideLength != 18 {
                Button { navigate(node, using: onCopy) } label: { Label("复制到新位置", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("copyLogicalNode")
            }
            if let onConnect {
                Button { navigate(node, using: onConnect) } label: { Label("连接另一个 LN", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            }
            if let onCreateInstance, MapNodeEditorRules.canInstantiate(node) {
                Button { navigate(node, using: onCreateInstance) } label: { Label("新增这个类的实例", systemImage: "plus.square.on.square") }
            }
            if onDelete != nil && canEdit {
                Button("删除节点", role: .destructive) { confirmingDelete = true }.accessibilityIdentifier("deleteLogicalNode")
            }
        }
    }

    private func navigate(_ target: MapLogicalNode, using action: ((MapLogicalNode) -> Void)?) {
        guard !busy, let action else { return }
        guard !changedProperties else {
            conflictLocation = nil
            error = "节点内容尚未保存。请先保存，再移动、复制、连接或创建关联实例。"; return
        }
        action(target)
        dismiss()
    }

    private func changeSize(_ size: Int) {
        guard node == nil else { return }
        sideLength = size
        let defaults = MapNodeEditorRules.defaults(size: size)
        value = defaults.value; logic = defaults.logicLanguage; operandKind = defaults.operandKind
        followsClassValue = size == 12
        automaticInstance = false; instanceParentCode = ""; error = nil; conflictLocation = nil
    }

    private func changeValue(_ text: String) {
        value = sideLength == 10 ? MapNodeEditorRules.normalizeInstance(text) : text
        if sideLength == 10 { logic = MapNodeEditorRules.instanceExpression(value) }
        if sideLength == 12 && followsClassValue { logic = MapNodeEditorRules.uppercase(value) }
    }

    private func changeBranch(_ branch: String) {
        logic = MapNodeEditorRules.switchBranch(from: value, to: branch, logic: logic)
        value = branch
    }

    private func save() {
        guard !busy, canEdit else { return }
        conflictLocation = nil
        guard let centerX = Double(x), let centerY = Double(y), centerX.isFinite, centerY.isFinite,
              centerX.truncatingRemainder(dividingBy: 1) == 0.5, centerY.truncatingRemainder(dividingBy: 1) == 0.5 else {
            error = "中心 X、Y 都必须为整数＋0.5，例如 100.5。"; return
        }
        let radius = Double(sideLength) / 2
        guard centerX - radius >= 0, centerY - radius >= 0, centerX + radius <= 500_000, centerY + radius <= 500_000 else {
            error = "节点的整个范围必须位于 0–500000 内。"; return
        }
        if isAutomaticInstance && automaticParent == nil { error = "请选择可以创建实例的 LN12。"; return }
        var properties = submittedProperties
        if isAutomaticInstance { properties.value = ""; properties.logicLanguage = "" }
        if let problem = MapNodeEditorRules.validation(properties: properties, size: sideLength,
                                                     isNew: node == nil, automaticInstance: isAutomaticInstance) {
            error = problem; return
        }
        if sideLength == 12 && node == nil && followsClassValue { properties.logicLanguage = "" }
        let draft = MapNodeEditorDraft(x: centerX, y: centerY, sideLength: sideLength, properties: properties,
                                       instanceParentCode: isAutomaticInstance ? instanceParentCode : nil)
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await onSave(draft); dismiss() }
            catch {
                if let apiError = error as? MapAPIError,
                   ["DuplicateLogicalNodeValue", "DuplicateLogicalNodeLogic"].contains(apiError.code) {
                    // These messages quote user-authored values/expressions.
                    // Keep them verbatim even if location parsing fails.
                    self.error = apiError.message
                } else { self.error = error.localizedDescription }
                conflictLocation = MapNodeConflictLocation.parse(error)
            }
        }
    }

    private func delete() {
        guard !busy, canEdit, let node, let onDelete else { return }
        busy = true; error = nil; conflictLocation = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await onDelete(node); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private static func coordinate(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
}

/// Mirrors presentation rules only. Save requests still go through Server validation.
enum MapNodeEditorRules {
    static let relations: [(symbol: String, name: String)] = [
        ("=", "等同"), ("→", "蕴含"), ("↔", "等价"), ("¬", "非（NOT）"),
        ("⊇", "包含（允许相等）"), ("⊋", "真包含"), ("⊆", "包含于（允许相等）"), ("⊊", "真包含于")
    ]
    // .NET's en-US casing uses simple mappings (e.g. ß stays ß when uppercased,
    // and Σ always lowers to σ). Swift's full-string casing expands ligatures
    // and applies final-sigma context, which would change the stored expression.
    static func uppercase(_ text: String) -> String { simpleCase(text, upper: true) }
    static func lowercase(_ text: String) -> String { simpleCase(text, upper: false) }
    private static func simpleCase(_ text: String, upper: Bool) -> String {
        text.unicodeScalars.map { scalar in
            if !upper && scalar.value == 0x0130 { return "i" }
            let original = String(scalar)
            let mapped = upper ? original.uppercased(with: Locale(identifier: "en_US")) : original.lowercased(with: Locale(identifier: "en_US"))
            return mapped.unicodeScalars.count == 1 ? mapped : original
        }.joined()
    }
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n\u{B}\u{C}\u{85}\u{2028}\u{2029}")).joined(separator: " ")
    }
    static func relationLogic(_ value: String) -> String { value == "¬" ? "¬(?)" : value }
    static func operandLogic(_ text: String, kind: String) -> String {
        kind == "Class" ? uppercase(text) : kind == "Instance" ? lowercase(text) : text
    }
    static func branchSource(value: String, logic: String) -> String? {
        guard !logic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if value == "True" { return logic }
        return value == "False" && logic.hasPrefix("¬") && logic.count > 1 ? String(logic.dropFirst()) : nil
    }
    static func switchBranch(from: String, to: String, logic: String) -> String {
        guard !logic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return logic }
        if from == "True" && to == "False" { return "¬" + logic }
        if from == "False" && to == "True" && logic.hasPrefix("¬") { return String(logic.dropFirst()) }
        return logic
    }
    static func normalizeInstance(_ value: String) -> String {
        guard let open = value.firstIndex(of: "(") else { return lowercase(value) }
        return lowercase(String(value[..<open])) + String(value[open...])
    }
    static func instanceParent(_ value: String) -> String { uppercase(String(value.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)[0])) }
    static func validInstance(_ value: String) -> Bool {
        guard value.utf16.count <= 220, let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")"), open < close,
              !String(value[..<open]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value[value.index(after: open)...].contains("("), !value[value.index(after: close)...].contains(")") else { return false }
        let tail = String(value[value.index(after: close)...])
        if !tail.isEmpty && (tail.first?.isWhitespace != true || tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { return false }
        let content = String(value[value.index(after: open)..<close])
        if content.isEmpty { return true }
        return content.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { attribute in
            guard let equals = attribute.firstIndex(of: "=") else { return false }
            return !attribute[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !attribute[attribute.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    static func instanceExpression(_ value: String) -> String {
        let parent = instanceParent(value)
        guard validInstance(value), let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")") else { return value + "∈" + parent }
        let alias = value[value.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        var expression = (alias.isEmpty ? value : alias) + "∈" + parent
        let content = value[value.index(after: open)..<close]
        if !content.isEmpty {
            for attribute in content.split(separator: ",", omittingEmptySubsequences: false) {
                guard let equals = attribute.firstIndex(of: "=") else { continue }
                expression += "∧" + String(attribute[attribute.index(after: equals)...]) + "∈" + parent + "." + uppercase(String(attribute[..<equals]))
            }
        }
        return expression
    }
    static func canInstantiate(_ node: MapLogicalNode) -> Bool {
        node.sideLength == 12 && node.properties.value.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) } &&
            !node.properties.value.contains("(") && !node.properties.value.contains(")") &&
            instanceParent(normalizeInstance(node.properties.value)) == node.properties.value
    }
    static func defaults(size: Int) -> MapNodeProperties {
        switch size {
        case 4: return MapNodeProperties(value: "False", info: "", logicLanguage: "", operandKind: "Custom")
        case 8: return MapNodeProperties(value: "=", info: "", logicLanguage: "=", operandKind: "Custom")
        case 10: return MapNodeProperties(value: "", info: "", logicLanguage: "", operandKind: "Custom")
        case 12: return MapNodeProperties(value: "逻辑节点", info: "", logicLanguage: "逻辑节点", operandKind: "Custom")
        case 18: return MapNodeProperties(value: "开始", info: "", logicLanguage: "", operandKind: "Custom")
        default: return MapNodeProperties()
        }
    }
    static func validation(properties p: MapNodeProperties, size: Int, isNew: Bool, automaticInstance: Bool = false) -> String? {
        if singleLine(p.value) != p.value || singleLine(p.logicLanguage) != p.logicLanguage { return "值和逻辑语言只能为单行；说明可以换行。" }
        if p.value.utf16.count > (size == 10 ? 220 : 32) || p.logicLanguage.utf16.count > (size == 10 ? 4096 : 255) || p.info.utf16.count > 255 {
            return "LN10 值最多 220 字符、逻辑语言最多 4096 字符；其他 LN 值最多 32 字符、逻辑语言最多 255 字符；说明最多 255 字符。"
        }
        if (!isNew && size == 6 || size == 12) && p.logicLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "此节点的逻辑语言不能为空。" }
        if size == 10 && !automaticInstance && !validInstance(p.value) { return "请输入 类名小写() 或 类名小写(属性=值)，括号后可用空格填写别名。例如 human(name=Alice) a。" }
        return nil
    }
    static func sizeLabel(_ size: Int) -> String {
        switch size {
        case 4: return "LN4 · 是 / 否分支"
        case 6: return "LN6 · 命题"
        case 8: return "LN8 · 关系 / 非"
        case 10: return "LN10 · 实例"
        case 12: return "LN12 · 类 / 集合"
        default: return "LN18 · 开始（全图唯一）"
        }
    }
    static func hint(size: Int) -> String {
        switch size {
        case 4: return "可选择一个 LN6 命题。True 对应 P，False 对应 ¬P；切换时自动添加或去掉最前面的一个 ¬。也可以不关联命题。"
        case 6: return "逻辑语言在全图 LN6 中唯一。新建时留空会自动生成临时命题；编辑时必须填写。"
        case 8: return "逻辑语言自动生成。非为 ¬(?)，问号表示待指定的输入命题；其他关系按图中顺序阅读。"
        case 10: return "类名前缀自动小写，属性和别名保留原文；逻辑语言自动生成。对应 LN12 必须存在。"
        case 12: return "值保存为大写且全图唯一。新建时逻辑语言默认跟随值，也可以单独填写。已有实例时，改名会同步关联实例。"
        default: return "全图只能有一个 LN18 开始节点。"
        }
    }
}

private struct MapNodeSourcePicker: View {
    let nodes: [MapLogicalNode]
    let onChoose: (MapLogicalNode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var filtered: [MapLogicalNode] {
        nodes.filter { search.isEmpty || $0.properties.value.localizedCaseInsensitiveContains(search) || $0.properties.logicLanguage.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search) }
            .sorted { $0.code < $1.code }
    }
    var body: some View {
        NavigationStack {
            List(filtered) { node in
                Button { onChoose(node); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.properties.logicLanguage).foregroundStyle(.primary)
                        Text("\(node.properties.value) · \(node.code)").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
            .searchable(text: $search, prompt: "搜索命题、逻辑语言或编码")
            .navigationTitle("选择 LN6 命题").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
