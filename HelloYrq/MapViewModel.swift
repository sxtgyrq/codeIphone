import Foundation
import Combine

enum MapCalculationKind: String, CaseIterable, Identifiable, Sendable {
    case cross, logicalNodes
    var id: String { rawValue }
    var title: String { self == .cross ? "计算 Cross" : "计算 LN 关联" }
}

@MainActor
final class MapViewModel: ObservableObject {
    @Published var serverAddress: String
    @Published var userName: String
    @Published private(set) var session: MapSession?
    @Published private(set) var snapshot: MapSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var calculationStatus: String?
    @Published private(set) var isCalculating = false
    @Published private(set) var requiresRefreshBeforeWrite = false
    @Published private(set) var hasPendingUndo = false

    private let defaults: UserDefaults
    private let makeAPI: (URL) -> MapAPI
    private var api: MapAPI?
    private var work: Task<Void, Never>?
    private var cancelForeground: (() -> Void)?
    private var foregroundID: UUID?
    private var foregroundMutationKey: String?
    private var calculation: Task<Void, Never>?
    private var calculationID: UUID?
    private var backgroundLease: UUID?
    private var generation = UUID()
    private var revision: UInt64 = 0

    init(defaults: UserDefaults = .standard, makeAPI: @escaping (URL) -> MapAPI = { MapAPI(serverURL: $0) }) {
        self.defaults = defaults
        self.makeAPI = makeAPI
        serverAddress = defaults.string(forKey: "map.serverAddress") ?? ""
        userName = defaults.string(forKey: "map.userName") ?? ""
    }

    static func applicationModel() -> MapViewModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return MapUITestSupport.makeModel() }
        #endif
        return MapViewModel()
    }

    func login(password: String) {
        guard !isWorking else { return }
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            errorMessage = "请输入用户名和密码。"
            return
        }
        do {
            let url = try MapAPI.normalizedURL(serverAddress)
            let candidate = makeAPI(url)
            stopCalculation()
            generation = UUID()
            let currentGeneration = generation
            let requestID = beginForeground()
            errorMessage = nil; notice = nil
            work = Task { [weak self] in
                guard let self else { return }
                defer { self.endForeground(requestID) }
                do {
                    let account = try await candidate.login(userName: name, password: password)
                    try self.requireCurrent(currentGeneration)
                    self.api = candidate; self.session = account
                    self.userName = name; self.serverAddress = url.absoluteString
                    // Credentials stay in memory. Recovery markers contain only random
                    // request IDs and booleans, scoped by the server and account name.
                    self.defaults.set(url.absoluteString, forKey: "map.serverAddress")
                    self.defaults.set(name, forKey: "map.userName")
                    self.restoreRecoveryState()
                    let map = try await candidate.loadMap(session: account)
                    try self.requireCurrent(currentGeneration)
                    self.publish(map)
                    if self.hasPendingUndo { self.notice = "上次撤销结果尚未确认，请再次点“撤销”确认同一笔请求。" }
                    else if self.requiresRefreshBeforeWrite { self.notice = "上次保存结果尚未确认，请检查地图并点击刷新后继续编辑。" }
                } catch { self.handle(error, generation: currentGeneration) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() {
        guard !isWorking, let account = session, let client = api else { return }
        let currentGeneration = generation
        let requestID = beginForeground()
        revision &+= 1
        errorMessage = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.endForeground(requestID) }
            do {
                try await self.waitForBackground(generation: currentGeneration)
                let map = try await client.loadMap(session: account)
                try self.requireCurrent(currentGeneration)
                self.publish(map)
                self.markVerification(self.identity(client: client, session: account), needed: false)
                self.notice = self.hasPendingUndo ? "地图已刷新。上次撤销仍待确认，请再次点“撤销”。" : "地图已刷新。"
            } catch { self.handle(error, generation: currentGeneration) }
        }
    }

    /// Serializes foreground work. A confirmed mutation remains successful even
    /// when the follow-up read fails; retrying the write could create duplicates.
    func execute<T: Sendable>(_ label: String, mutation: Bool = true, refresh: Bool = true,
                             operation: @escaping @MainActor (MapAPI, MapSession) async throws -> T) async throws -> T {
        try await executeCore(label, mutation: mutation, refresh: refresh, recoveryUndo: false, operation: operation)
    }

    private func executeCore<T: Sendable>(_ label: String, mutation: Bool, refresh: Bool, recoveryUndo: Bool,
                                         operation: @escaping @MainActor (MapAPI, MapSession) async throws -> T) async throws -> T {
        guard !isWorking else { throw localError("Busy", "正在处理上一项操作，请稍候。") }
        guard let account = session, let client = api else { throw localError("LoginExpired", "请先登录。") }
        if mutation && !recoveryUndo { try checkWriteAllowed() }
        try Task.checkCancellation()
        let currentGeneration = generation
        let requestID = beginForeground()
        let identity = identity(client: client, session: account)
        revision &+= 1
        errorMessage = nil; notice = nil
        defer { endForeground(requestID) }
        try await waitForBackground(generation: currentGeneration)
        try requireCurrent(currentGeneration)
        errorMessage = nil
        if mutation { foregroundMutationKey = identity }
        let operationTask = Task { try await operation(client, account) }
        cancelForeground = { operationTask.cancel() }
        let result: T
        do {
            result = try await withTaskCancellationHandler(operation: { try await operationTask.value },
                                                          onCancel: { operationTask.cancel() })
        } catch {
            if mutation && uncertain(error) { markVerification(identity, needed: true) }
            else if mutation && (error as? MapAPIError)?.code == "VersionConflict" { markVerification(identity, needed: true) }
            handle(error, generation: currentGeneration)
            throw error
        }
        do { try requireCurrent(currentGeneration) }
        catch {
            if mutation { markVerification(identity, needed: true) }
            throw error
        }
        foregroundMutationKey = nil
        if mutation {
            markVerification(identity, needed: false)
            notice = completionMessage(label)
        }
        if refresh {
            do {
                let map = try await client.loadMap(session: account)
                try requireCurrent(currentGeneration)
                publish(map)
            } catch {
                guard generation == currentGeneration else { throw CancellationError() }
                handle(error, generation: currentGeneration)
                if mutation {
                    markVerification(identity, needed: true)
                    notice = "\(completionMessage(label))地图刷新失败，请刷新查看已保存的结果，不要重复提交。"
                    errorMessage = "操作已保存。刷新失败：\(error.localizedDescription) 请勿重复提交。"
                    // The operation already returned success. Never reclassify it as a failed write.
                    return result
                }
                throw error
            }
        }
        return result
    }

    func undoLastOperation() async throws {
        guard !isWorking else { throw localError("Busy", "正在处理上一项操作，请稍候。") }
        guard let account = session, let client = api else { throw localError("LoginExpired", "请先登录。") }
        let identity = identity(client: client, session: account)
        let key = "map.pendingUndo." + identity
        let previousID = defaults.string(forKey: key)
        if previousID == nil && requiresRefreshBeforeWrite {
            throw localError("RefreshRequired", "请先刷新并检查上次保存结果，再选择要撤销的操作。")
        }
        let id = previousID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: key)
        hasPendingUndo = true
        let currentGeneration = generation
        do {
            let result = try await executeCore("撤销", mutation: true, refresh: false, recoveryUndo: true) { client, account in
                try await client.undoMap(requestID: id, session: account)
            }
            defaults.removeObject(forKey: key)
            try requireCurrent(currentGeneration)
            hasPendingUndo = false
            publish(result.map)
            notice = "已撤销：\(result.operation)。"
        } catch {
            if !uncertain(error) {
                defaults.removeObject(forKey: key)
                if currentIdentity == identity { hasPendingUndo = false }
            }
            throw error
        }
    }

    func startCalculation(_ kind: MapCalculationKind) {
        guard !isCalculating, let account = session, let client = api else { return }
        do { try checkWriteAllowed() }
        catch { errorMessage = error.localizedDescription; return }
        let id = UUID()
        let currentGeneration = generation
        calculationID = id
        isCalculating = true
        calculationStatus = "\(kind.title)：等待处理…"
        calculation = Task { [weak self] in
            guard let self else { return }
            var cursor: String?
            do {
                while true {
                    try await self.waitForForeground(generation: currentGeneration)
                    let lease = UUID()
                    self.backgroundLease = lease
                    let canContinue: Bool
                    do {
                        if kind == .cross {
                            let progress = try await client.calculateCross(session: account)
                            try self.requireCurrent(currentGeneration)
                            guard progress.remainingSegments >= 0, progress.crossCount >= 0 else { throw self.localError("InvalidResponse", "交点计算返回了无效进度。") }
                            self.calculationStatus = "Cross：剩余 \(progress.remainingSegments) 段，共 \(progress.crossCount) 个交点"
                            canContinue = progress.canContinue
                        } else {
                            let progress = try await client.calculateLogicalNodes(afterCode: cursor, session: account)
                            try self.requireCurrent(currentGeneration)
                            guard progress.remainingNodes >= 0, progress.nodeCount >= 0 else { throw self.localError("InvalidResponse", "LN 计算返回了无效进度。") }
                            if progress.canContinue {
                                guard let next = progress.nextCode, next.utf8.count == 10,
                                      next.utf8.allSatisfy({ (65...90).contains($0) }), cursor.map({ next > $0 }) ?? true else {
                                    throw self.localError("InvalidCalculationCursor", "LN 计算游标没有前进，计算已停止。请刷新后重试。")
                                }
                                cursor = next
                            }
                            self.calculationStatus = "LN：剩余 \(progress.remainingNodes) 个，共 \(progress.nodeCount) 个节点"
                            canContinue = progress.canContinue
                        }
                    } catch {
                        if self.backgroundLease == lease { self.backgroundLease = nil }
                        throw error
                    }
                    if self.backgroundLease == lease { self.backgroundLease = nil }
                    if !canContinue { break }
                    // Yield after each transaction so taps and foreground requests take priority.
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try await self.waitForForeground(generation: currentGeneration)
                let lease = UUID()
                self.backgroundLease = lease
                let readRevision = self.revision
                do {
                    let map = try await client.loadMap(session: account)
                    try self.requireCurrent(currentGeneration)
                    if self.revision == readRevision && !self.isWorking { self.publish(map) }
                } catch {
                    if self.backgroundLease == lease { self.backgroundLease = nil }
                    throw error
                }
                if self.backgroundLease == lease { self.backgroundLease = nil }
                guard self.calculationID == id else { return }
                self.calculationStatus = "\(kind.title)完成。"
            } catch {
                guard self.calculationID == id else { return }
                if error is CancellationError { self.calculationStatus = "已停止计算。" }
                else {
                    self.calculationStatus = "\(kind.title)已停止。"
                    self.handle(error, generation: currentGeneration)
                }
            }
            if self.calculationID == id {
                self.isCalculating = false; self.calculationID = nil; self.calculation = nil
            }
        }
    }

    func stopCalculation() {
        calculationID = nil
        calculation?.cancel(); calculation = nil
        if isCalculating { calculationStatus = "已停止计算。" }
        isCalculating = false
    }

    func logout() {
        let previousSession = session
        let previousAPI = api
        invalidateSession()
        errorMessage = nil; notice = nil
        if let account = previousSession, let client = previousAPI {
            Task { try? await client.logout(session: account) }
        }
    }

    private func invalidateSession() {
        if let key = foregroundMutationKey { markVerification(key, needed: true) }
        generation = UUID(); revision &+= 1
        stopCalculation(); calculationStatus = nil
        work?.cancel(); work = nil
        cancelForeground?(); cancelForeground = nil
        foregroundID = nil; foregroundMutationKey = nil
        session = nil; snapshot = nil; api = nil; lastRefresh = nil
        isWorking = false; requiresRefreshBeforeWrite = false; hasPendingUndo = false
    }

    private func beginForeground() -> UUID {
        let id = UUID(); foregroundID = id; isWorking = true
        return id
    }

    private func endForeground(_ id: UUID) {
        guard foregroundID == id else { return }
        foregroundID = nil; foregroundMutationKey = nil; cancelForeground = nil; isWorking = false
    }

    private func waitForBackground(generation expected: UUID) async throws {
        while backgroundLease != nil {
            try requireCurrent(expected)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try requireCurrent(expected)
    }

    private func waitForForeground(generation expected: UUID) async throws {
        while isWorking || backgroundLease != nil {
            try requireCurrent(expected)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try requireCurrent(expected)
        try checkWriteAllowed()
    }

    private func requireCurrent(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func publish(_ map: MapSnapshot) {
        snapshot = map; lastRefresh = Date(); revision &+= 1
    }

    private var currentIdentity: String? {
        guard let client = api, let account = session else { return nil }
        return identity(client: client, session: account)
    }

    private func identity(client: MapAPI, session: MapSession) -> String {
        Data((client.serverURL.absoluteString + "\n" + session.userName).utf8).base64EncodedString()
    }

    private func restoreRecoveryState() {
        guard let key = currentIdentity else { return }
        requiresRefreshBeforeWrite = defaults.bool(forKey: "map.verifyWrite." + key)
        hasPendingUndo = defaults.string(forKey: "map.pendingUndo." + key) != nil
    }

    private func markVerification(_ identity: String, needed: Bool) {
        if needed { defaults.set(true, forKey: "map.verifyWrite." + identity) }
        else { defaults.removeObject(forKey: "map.verifyWrite." + identity) }
        if currentIdentity == identity { requiresRefreshBeforeWrite = needed }
    }

    private func checkWriteAllowed() throws {
        if hasPendingUndo { throw localError("PendingUndo", "上次撤销结果尚未确认。请再次点“撤销”确认同一笔请求后再编辑。") }
        if requiresRefreshBeforeWrite { throw localError("RefreshRequired", "上次操作结果需要确认。请先刷新并检查地图，避免重复保存。") }
    }

    private func uncertain(_ error: Error) -> Bool {
        guard let service = error as? MapAPIError else { return true }
        return ["ConnectionFailure", "InvalidResponse", "HttpError", "DatabaseError", "LoginExpired"].contains(service.code)
    }

    private func handle(_ error: Error, generation expected: UUID) {
        guard generation == expected, !(error is CancellationError) else { return }
        if (error as? MapAPIError)?.isSessionExpired == true { invalidateSession() }
        errorMessage = error.localizedDescription
    }

    private func localError(_ code: String, _ message: String) -> MapAPIError { MapAPIError(code: code, message: message) }

    private func completionMessage(_ label: String) -> String {
        let message = label.contains("已") ? label : "\(label)已完成"
        return message.hasSuffix("。") ? message : message + "。"
    }
}
