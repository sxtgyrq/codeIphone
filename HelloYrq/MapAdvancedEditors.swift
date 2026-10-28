import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MapConnectionEditor: View {
    @ObservedObject var model: MapViewModel
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceCode: String
    @State private var targetCode: String
    @State private var kind: MapLogicalNodeConnectionKind = .direct
    @State private var preview: MapLogicalNodeConnectionPlan?
    @State private var phase: MapEditorPhase = .idle
    @State private var work: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var uncertainResult = false

    init(model: MapViewModel, source: MapLogicalNode?, target: MapLogicalNode?, onSaved: @escaping () -> Void) {
        self.model = model; self.onSaved = onSaved
        _sourceCode = State(initialValue: source?.code ?? "")
        _targetCode = State(initialValue: target?.code ?? "")
    }

    private var nodes: [MapLogicalNode] { model.snapshot?.logicalNodes ?? [] }
    private var source: MapLogicalNode? { nodes.first { $0.code == sourceCode } }
    private var target: MapLogicalNode? { nodes.first { $0.code == targetCode } }
    private var canPreview: Bool { source != nil && target != nil && sourceCode != targetCode && !uncertainResult }
    private var kindExplanation: String {
        switch kind {
        case .direct: return "新增一条线路，依次穿过起点和终点 LN。"
        case .goTo: return "新线穿过起点 LN，再接入已有通路前往终点 LN。"
        case .find: return "先沿已有通路从起点 LN 出发，再接出新线穿过终点 LN。"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接对象") {
                    NavigationLink {
                        MapNodeChoiceList(title: "选择起点 LN", nodes: nodes, selection: $sourceCode, excludedCode: targetCode)
                    } label: { LabeledContent("起点", value: source.map(nodeChoiceTitle) ?? "选择 LN") }
                        .accessibilityIdentifier("connectionSource")
                    NavigationLink {
                        MapNodeChoiceList(title: "选择终点 LN", nodes: nodes, selection: $targetCode, excludedCode: sourceCode)
                    } label: { LabeledContent("终点", value: target.map(nodeChoiceTitle) ?? "选择 LN") }
                        .accessibilityIdentifier("connectionTarget")
                }.disabled(phase != .idle)
                Section("连接方式") {
                    Picker("方式", selection: $kind) {
                        ForEach(MapLogicalNodeConnectionKind.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("connectionKind")
                    Text(kindExplanation).font(.footnote).foregroundStyle(.secondary)
                }.disabled(phase != .idle)
                Section {
                    Button { loadPreview() } label: {
                        HStack {
                            if phase == .previewing { ProgressView() }
                            Text(phase == .previewing ? "正在寻找通路…" : "预览连接")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(!canPreview || phase != .idle || model.isWorking)
                        .accessibilityIdentifier("previewConnection")
                }
                if let preview {
                    Section("连接预览") {
                        MapOperationPreview(snapshot: connectionSnapshot(preview), continuation: preview.continuation,
                                            highlightedLine: preview.lineCode)
                            .id(preview).accessibilityIdentifier("connectionPreview")
                        Text(preview.continuation.isEmpty ? "橙色线为即将新增的线路。" : "橙色线为新增线路，青色虚线为已有通路。箭头表示行进方向。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let join = preview.join {
                            Text("与线路 \(join.roadCode) 在 (\(Int(join.position.x)), \(Int(join.position.y))) 接通。")
                                .font(.footnote)
                        }
                        Text("确认后保存新线，并设置接入点和其余新交点的通行状态。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                operationError(errorMessage, uncertain: uncertainResult)
            }
            .navigationTitle("连接 LN").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: close).disabled(phase == .saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .saving ? "保存中…" : "确认连接", action: save)
                        .disabled(preview == nil || phase != .idle || uncertainResult || model.isWorking)
                        .accessibilityIdentifier("saveConnection")
                }
            }
            .interactiveDismissDisabled(phase == .saving)
            .onChange(of: sourceCode) { _ in invalidate() }
            .onChange(of: targetCode) { _ in invalidate() }
            .onChange(of: kind) { _ in invalidate() }
            .onChange(of: source.map { MapLogicalNodeConnectionAnchor(node: $0) }) { _ in invalidate() }
            .onChange(of: target.map { MapLogicalNodeConnectionAnchor(node: $0) }) { _ in invalidate() }
            .onDisappear { if phase != .saving { work?.cancel() } }
        }
    }

    private func connectionSnapshot(_ plan: MapLogicalNodeConnectionPlan) -> MapSnapshot {
        let line = MapLine(code: plan.lineCode, owner: model.session?.userName ?? "", isLocked: false,
                           version: 0, nodes: plan.nodes)
        return MapSnapshot(lines: [line], logicalNodes: [source, target].compactMap { $0 }, crosses: [])
    }
    private func invalidate() { preview = nil; errorMessage = nil }
    private func close() { work?.cancel(); dismiss() }
    private func loadPreview() {
        guard phase == .idle, canPreview, let source, let target else { return }
        let requestedKind = kind
        phase = .previewing; errorMessage = nil; preview = nil
        work = Task {
            do {
                let result = try await model.execute("预览 LN 连接", mutation: false, refresh: false) { api, session in
                    try await api.previewLogicalNodeConnection(source: source, target: target, kind: requestedKind, session: session)
                }
                guard !Task.isCancelled else { phase = .idle; return }
                if sourceCode == source.code, targetCode == target.code, kind == requestedKind,
                   self.source.map({ MapLogicalNodeConnectionAnchor(node: $0) }) == result.source,
                   self.target.map({ MapLogicalNodeConnectionAnchor(node: $0) }) == result.target {
                    preview = result
                } else { errorMessage = "节点位置已变化，请重新预览。" }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            phase = .idle
        }
    }
    private func save() {
        guard phase == .idle, !uncertainResult, let preview, preview.kind == kind,
              source.map({ MapLogicalNodeConnectionAnchor(node: $0) }) == preview.source,
              target.map({ MapLogicalNodeConnectionAnchor(node: $0) }) == preview.target else { return }
        phase = .saving; errorMessage = nil
        work = Task {
            do {
                _ = try await model.execute("连接 LN") { api, session in
                    try await api.saveLogicalNodeConnection(plan: preview, session: session)
                }
                onSaved(); dismiss()
            } catch {
                errorMessage = error.localizedDescription
                if uncertainMutation(error) { uncertainResult = true; self.preview = nil }
            }
            phase = .idle
        }
    }
}

@MainActor
struct MapMergeEditor: View {
    @ObservedObject var model: MapViewModel
    let first: MapLine
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var secondCode: String
    @State private var preview: MapMergePreview?
    @State private var planID = ""
    @State private var phase: MapEditorPhase = .idle
    @State private var work: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var uncertainResult = false

    init(model: MapViewModel, first: MapLine, second: MapLine?, onSaved: @escaping () -> Void) {
        self.model = model; self.first = first; self.onSaved = onSaved
        _secondCode = State(initialValue: second?.code ?? "")
    }
    private var eligibleLines: [MapLine] {
        (model.snapshot?.lines ?? []).filter {
            $0.code != first.code && $0.owner == model.session?.userName && !$0.isLocked && $0.nodes.count >= 2
        }.sorted { $0.code < $1.code }
    }
    private var second: MapLine? { eligibleLines.first { $0.code == secondCode } }
    private var chosenPlan: MapMergePlan? { preview?.plans.first { $0.id == planID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("合并顺序") {
                    LabeledContent("第一条", value: lineChoiceTitle(first))
                    NavigationLink {
                        MapLineChoiceList(lines: eligibleLines, selection: $secondCode)
                    } label: { LabeledContent("第二条", value: second.map(lineChoiceTitle) ?? "选择线路") }
                        .accessibilityIdentifier("mergeSecondLine")
                    Text("从第一条末端连接到第二条起点；确认后保留第一条线路的编码、名称、速度和通行方向。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(phase != .idle)
                Section {
                    Button { loadPreview() } label: {
                        HStack {
                            if phase == .previewing { ProgressView() }
                            Text(phase == .previewing ? "正在寻找方案…" : "查找合并方案")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(second == nil || phase != .idle || uncertainResult || model.isWorking)
                        .accessibilityIdentifier("previewMerge")
                }
                if let preview, let chosenPlan {
                    Section("选择方案") {
                        Picker("连接方向", selection: $planID) {
                            ForEach(preview.plans) { plan in
                                Text("\(mergeDirection(plan)) · 调整 \(plan.adjustedGridSteps) 格").tag(plan.id)
                            }
                        }.disabled(phase != .idle).accessibilityIdentifier("mergePlan")
                        Text("接角 \(chosenPlan.firstCorner)° / \(chosenPlan.secondCorner)°")
                            .font(.footnote).foregroundStyle(.secondary)
                        MapOperationPreview(snapshot: mergedSnapshot(preview, plan: chosenPlan), highlightedLine: preview.first.code)
                            .id(chosenPlan.id).accessibilityIdentifier("mergePreview")
                        Text("第一条末点 (\(chosenPlan.firstX), \(chosenPlan.firstY)) → 第二条起点 (\(chosenPlan.secondX), \(chosenPlan.secondY))")
                            .font(.footnote).monospacedDigit()
                        DisclosureGroup("查看原线路") {
                            MapOperationPreview(snapshot: MapSnapshot(lines: [preview.first, preview.second]))
                        }
                    }
                }
                operationError(errorMessage, uncertain: uncertainResult)
            }
            .navigationTitle("合并线路").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { work?.cancel(); dismiss() }.disabled(phase == .saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .saving ? "保存中…" : "确认合并", action: save)
                        .disabled(chosenPlan == nil || phase != .idle || uncertainResult || model.isWorking)
                        .accessibilityIdentifier("saveMerge")
                }
            }
            .interactiveDismissDisabled(phase == .saving)
            .onChange(of: secondCode) { _ in preview = nil; planID = ""; errorMessage = nil }
            .onChange(of: model.snapshot?.lines) { lines in
                guard let preview, let lines else { return }
                if lines.first(where: { $0.code == preview.first.code })?.version != preview.first.version ||
                    lines.first(where: { $0.code == preview.second.code })?.version != preview.second.version {
                    self.preview = nil; planID = ""; errorMessage = "线路已变化，请重新查找合并方案。"
                }
            }
            .onDisappear { if phase != .saving { work?.cancel() } }
        }
    }

    private func mergedSnapshot(_ preview: MapMergePreview, plan: MapMergePlan) -> MapSnapshot {
        guard preview.first.nodes.count >= 2, preview.second.nodes.count >= 2 else { return .empty }
        // This is the same exact endpoint adjustment shown by WPF. Server alone
        // adds any collinear subdivision points when committing long segments.
        var nodes = preview.first.nodes + preview.second.nodes
        let end = preview.first.nodes.count - 1
        nodes[end] = MapLinePoint(lineCode: preview.first.code, order: end, x: plan.firstX, y: plan.firstY)
        nodes[end + 1] = MapLinePoint(lineCode: preview.first.code, order: end + 1, x: plan.secondX, y: plan.secondY)
        nodes = nodes.enumerated().map {
            MapLinePoint(lineCode: preview.first.code, order: $0.offset, x: $0.element.x, y: $0.element.y)
        }
        let line = MapLine(code: preview.first.code, owner: preview.first.owner, isLocked: false,
                           version: preview.first.version, nodes: nodes, properties: preview.first.properties)
        return MapSnapshot(lines: [line])
    }
    private func loadPreview() {
        guard phase == .idle, !uncertainResult, let second else { return }
        let firstCode = first.code
        phase = .previewing; errorMessage = nil; preview = nil; planID = ""
        work = Task {
            do {
                let result = try await model.execute("预览线路合并", mutation: false, refresh: false) { api, session in
                    let currentFirst = try await api.lineDetail(lineCode: firstCode, session: session)
                    let currentSecond = try await api.lineDetail(lineCode: second.code, session: session)
                    return try await api.mergePlans(first: currentFirst, second: currentSecond, session: session)
                }
                guard !Task.isCancelled else { phase = .idle; return }
                guard result.first.nodes.count >= 2, result.second.nodes.count >= 2, !result.plans.isEmpty else {
                    throw MapAPIError(code: "InvalidResponse", message: "没有可用的合并方案，请刷新线路后重试。")
                }
                if secondCode == second.code { preview = result; planID = result.plans[0].id }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            phase = .idle
        }
    }
    private func save() {
        guard phase == .idle, !uncertainResult, let preview, let chosenPlan else { return }
        phase = .saving; errorMessage = nil
        work = Task {
            do {
                _ = try await model.execute("合并线路") { api, session in
                    try await api.mergeLines(preview: preview, plan: chosenPlan, session: session)
                }
                onSaved(); dismiss()
            } catch {
                errorMessage = error.localizedDescription
                if uncertainMutation(error) { uncertainResult = true; self.preview = nil }
            }
            phase = .idle
        }
    }
}

@MainActor
struct MapFlowImportEditor: View {
    @ObservedObject var model: MapViewModel
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedInput: String?
    @State private var text = ""
    @State private var xText: String
    @State private var yText: String
    @State private var showFileImporter = false
    @State private var preview: MapFlowDiagramResult?
    @State private var previewInput: MapFlowInput?
    @State private var phase: MapEditorPhase = .idle
    @State private var work: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var uncertainResult = false

    init(model: MapViewModel, center: CGPoint, onSaved: @escaping () -> Void) {
        self.model = model; self.onSaved = onSaved
        _xText = State(initialValue: String(format: "%.1f", min(499_999, max(0, floor(Double(center.x)))) + 0.5))
        _yText = State(initialValue: String(format: "%.1f", min(499_999, max(0, floor(Double(center.y)))) + 0.5))
    }
    private var input: MapFlowInput? {
        guard let x = Double(xText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(yText.trimmingCharacters(in: .whitespacesAndNewlines)),
              x.isFinite, y.isFinite, (0...500_000).contains(x), (0...500_000).contains(y),
              x.truncatingRemainder(dividingBy: 1) == 0.5, y.truncatingRemainder(dividingBy: 1) == 0.5,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 1_000_000 else { return nil }
        return MapFlowInput(text: text, x: x, y: y)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("流程图数据") {
                    HStack {
                        PasteButton(payloadType: String.self) { values in if let value = values.first { replaceText(value) } }
                            .accessibilityIdentifier("pasteFlowJSON")
                        Spacer()
                        Button { showFileImporter = true } label: { Label("从文件导入", systemImage: "doc") }
                            .frame(minHeight: 44).accessibilityIdentifier("openFlowFile")
                    }
                    HStack {
                        Text("JSON 文本").font(.subheadline)
                        Spacer()
                        Button("清空") { replaceText("") }
                            .buttonStyle(.borderless).frame(minHeight: 44)
                            .accessibilityLabel("清空流程图 JSON").accessibilityIdentifier("clear-flowJSON")
                    }
                    TextEditor(text: $text).font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 170).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedInput, equals: "flowJSON")
                        .accessibilityLabel("流程图 JSON").accessibilityIdentifier("flowJSON")
                    Text("使用 ArgumentMap Flow v1 JSON。先预览，确认布局后再导入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(phase != .idle)
                Section("插入位置") {
                    coordinateField("中心 X", value: $xText, id: "flowOriginX")
                    coordinateField("中心 Y", value: $yText, id: "flowOriginY")
                    Text("这里对应 JSON 中 origin 指定的 LN 中心，坐标须为整数 + 0.5。默认使用刚才的地图落点。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(phase != .idle)
                Section {
                    Button { loadPreview() } label: {
                        HStack {
                            if phase == .previewing { ProgressView() }
                            Text(phase == .previewing ? "正在校验…" : "校验并预览")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(input == nil || phase != .idle || uncertainResult || model.isWorking)
                        .accessibilityIdentifier("previewFlow")
                    if text.utf16.count > 1_000_000 {
                        Text("一次最多导入 100 万字符，请缩小数据范围。").font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let preview {
                    Section("导入预览") {
                        MapOperationPreview(snapshot: preview.added).id(previewInput)
                            .accessibilityIdentifier("flowPreview")
                        Text("新增 \(preview.added.lines.count) 条线路、\(preview.added.logicalNodes.count) 个 LN、\(preview.added.crosses.count) 个 Cross。")
                            .font(.footnote)
                        ForEach(Array(preview.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                operationError(errorMessage, uncertain: uncertainResult)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("flowImportForm")
            .navigationTitle("导入流程图").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { work?.cancel(); dismiss() }.disabled(phase == .saving)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { focusedInput = nil } label: {
                        Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44)
                    }
                    .disabled(focusedInput == nil)
                    .accessibilityLabel("收起键盘").accessibilityIdentifier("dismissFlowKeyboard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .saving ? "导入中…" : "确认导入", action: save)
                        .disabled(preview == nil || input != previewInput || phase != .idle || uncertainResult || model.isWorking)
                        .accessibilityIdentifier("saveFlow")
                }
            }
            .interactiveDismissDisabled(phase == .saving)
            .onChange(of: text) { _ in invalidate() }
            .onChange(of: xText) { _ in invalidate() }
            .onChange(of: yText) { _ in invalidate() }
            .onDisappear { if phase != .saving { work?.cancel() } }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: false) { result in
                readFile(result)
            }
        }
    }

    private func coordinateField(_ title: String, value: Binding<String>, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("整数 + 0.5", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .focused($focusedInput, equals: id)
                .frame(maxWidth: 160).accessibilityIdentifier(id)
            Button { value.wrappedValue = "" } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel("清空 " + title).accessibilityIdentifier("clear-" + id)
        }
    }
    private func invalidate() { preview = nil; previewInput = nil; errorMessage = nil }
    private func replaceText(_ value: String) {
        guard value.utf16.count <= 1_000_000 else { errorMessage = "流程图文本不能超过 100 万字符。"; return }
        text = value
    }
    private func readFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4_000_000 else { throw MapLineDraftError("文件过大，一次最多导入 100 万字符。") }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 4_000_001) ?? Data()
            guard data.count <= 4_000_000, var value = String(data: data, encoding: .utf8) else {
                throw MapLineDraftError("请使用 UTF-8 编码的 JSON 或文本文件。")
            }
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
            replaceText(value)
        } catch { errorMessage = error.localizedDescription }
    }
    private func loadPreview() {
        guard phase == .idle, !uncertainResult, let input else { return }
        phase = .previewing; errorMessage = nil; preview = nil; previewInput = nil
        work = Task {
            do {
                let result = try await model.execute("预览流程图", mutation: false, refresh: false) { api, session in
                    try await api.previewFlowDiagram(text: input.text, x: input.x, y: input.y, session: session)
                }
                guard !Task.isCancelled else { phase = .idle; return }
                if self.input == input { preview = result; previewInput = input }
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            phase = .idle
        }
    }
    private func save() {
        guard phase == .idle, !uncertainResult, preview != nil, let input = previewInput, self.input == input else { return }
        phase = .saving; errorMessage = nil
        work = Task {
            do {
                _ = try await model.execute("导入流程图") { api, session in
                    try await api.importFlowDiagram(text: input.text, x: input.x, y: input.y, session: session)
                }
                onSaved(); dismiss()
            } catch {
                errorMessage = error.localizedDescription
                if uncertainMutation(error) { uncertainResult = true; preview = nil; previewInput = nil }
            }
            phase = .idle
        }
    }
}

private enum MapEditorPhase { case idle, previewing, saving }
private struct MapFlowInput: Hashable { let text: String; let x: Double; let y: Double }

@MainActor
private struct MapOperationPreview: View {
    let snapshot: MapSnapshot
    let highlightedLine: String?
    @StateObject private var interaction: MapInteraction

    init(snapshot: MapSnapshot, continuation: [MapLogicalNodeContinuationPoint] = [], highlightedLine: String? = nil) {
        self.snapshot = snapshot; self.highlightedLine = highlightedLine
        let interaction = MapInteraction()
        interaction.continuation = continuation
        interaction.selectedID = highlightedLine.map { "line:\($0)" }
        _interaction = StateObject(wrappedValue: interaction)
    }
    var body: some View {
        MapCanvasView(interaction: interaction, snapshot: snapshot, showArrows: true, showLabels: true,
                      showCrosses: true, fitRequest: 0, onSelect: { _ in
                          interaction.selectedID = highlightedLine.map { "line:\($0)" }
                      })
            .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct MapNodeChoiceList: View {
    let title: String
    let nodes: [MapLogicalNode]
    @Binding var selection: String
    let excludedCode: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private var filtered: [MapLogicalNode] {
        nodes.filter { $0.code != excludedCode && (query.isEmpty || $0.code.localizedCaseInsensitiveContains(query) ||
            $0.properties.value.localizedCaseInsensitiveContains(query) || $0.properties.logicLanguage.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.code < $1.code }
    }
    var body: some View {
        List(filtered) { node in
            Button {
                selection = node.code; dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(nodeChoiceTitle(node)).font(.headline)
                        if !node.properties.logicLanguage.isEmpty {
                            Text(node.properties.logicLanguage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(node.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if node.code == selection { Image(systemName: "checkmark") }
                }.frame(minHeight: 44)
            }.foregroundStyle(.primary).accessibilityIdentifier("chooseNode-\(node.code)")
        }
        .searchable(text: $query, prompt: "搜索值、逻辑语言或编码")
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct MapLineChoiceList: View {
    let lines: [MapLine]
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(lines.filter { query.isEmpty || $0.code.localizedCaseInsensitiveContains(query) ||
            $0.properties.roadName.localizedCaseInsensitiveContains(query) }) { line in
            Button {
                selection = line.code; dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(lineChoiceTitle(line))
                        Text("\(line.nodes.count) 个节点 · \(line.code)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if line.code == selection { Image(systemName: "checkmark") }
                }.frame(minHeight: 44)
            }.foregroundStyle(.primary).accessibilityIdentifier("chooseMergeLine-\(line.code)")
        }
        .searchable(text: $query, prompt: "搜索线路名称或编码")
        .navigationTitle("选择第二条线路").navigationBarTitleDisplayMode(.inline)
        .overlay {
            if lines.isEmpty { Text("没有可合并的其他线路。需要本人创建、未锁定且至少有两个节点的线路。").foregroundStyle(.secondary).padding(28) }
        }
    }
}

@ViewBuilder
private func operationError(_ message: String?, uncertain: Bool) -> some View {
    if let message {
        Section {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                .accessibilityIdentifier("advancedEditorError")
            if uncertain {
                Text("操作结果尚未确认。请先返回地图刷新并检查，避免重复提交；当前输入仍保留在此窗口中。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private func uncertainMutation(_ error: Error) -> Bool {
    guard let error = error as? MapAPIError else { return true }
    return ["ConnectionFailure", "InvalidResponse", "HttpError", "DatabaseError", "LoginExpired", "Cancelled"].contains(error.code)
}
private func nodeChoiceTitle(_ node: MapLogicalNode) -> String {
    "LN\(node.sideLength) · \(node.properties.value.isEmpty ? node.code : node.properties.value)"
}
private func lineChoiceTitle(_ line: MapLine) -> String {
    line.properties.roadName.isEmpty ? line.code : line.properties.roadName
}
private func mergeDirection(_ plan: MapMergePlan) -> String {
    switch (plan.directionX, plan.directionY) {
    case (1, 0): return "向右"
    case (1, 1): return "右上"
    case (0, 1): return "向上"
    case (-1, 1): return "左上"
    case (-1, 0): return "向左"
    case (-1, -1): return "左下"
    case (0, -1): return "向下"
    default: return "右下"
    }
}
