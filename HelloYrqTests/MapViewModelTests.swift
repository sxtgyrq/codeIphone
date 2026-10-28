import Foundation
import XCTest
@testable import HelloYrq

@MainActor
final class MapViewModelTests: XCTestCase {
    private var transport: URLSession!
    private var preferences: UserDefaults!
    private var preferencesName = ""
    private var server: MapVMFixtureServer!

    override func setUp() async throws {
        try await super.setUp()
        preferencesName = "ArgumentMap.VMTests." + UUID().uuidString
        preferences = UserDefaults(suiteName: preferencesName)!
        server = MapVMFixtureServer()
        let fixture = server!
        MapVMProtocol.install { try fixture.respond(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapVMProtocol.self]
        transport = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        transport.invalidateAndCancel()
        preferences.removePersistentDomain(forName: preferencesName)
        MapVMProtocol.install(nil)
        transport = nil; preferences = nil; server = nil
        try await super.tearDown()
    }

    private func makeModel() -> MapViewModel {
        let session = transport!
        let model = MapViewModel(defaults: preferences, makeAPI: { MapAPI(serverURL: $0, session: session) })
        model.serverAddress = "http://192.168.1.20:61011"
        model.userName = "editor"
        return model
    }

    private func loggedIn() async throws -> MapViewModel {
        let model = makeModel()
        model.login(password: "fixture-secret")
        try await wait { !model.isWorking }
        XCTAssertEqual(model.session?.userName, "editor")
        XCTAssertNotNil(model.snapshot)
        return model
    }

    private func wait(timeout: TimeInterval = 3, _ predicate: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for model state", file: file, line: line)
    }

    private func assertCode<T>(_ expected: String, operation: () async throws -> T,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as MapAPIError { XCTAssertEqual(error.code, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    func testConfirmedSaveWithRefreshFailureReturnsSuccessAndKeepsPreviousMap() async throws {
        let model = try await loggedIn()
        let previous = model.snapshot
        server.setReadFailure("DatabaseError")
        let saved = try await model.execute("新增 LN") { _, _ in "confirmed-save" }
        XCTAssertEqual(saved, "confirmed-save")
        XCTAssertEqual(model.snapshot, previous)
        XCTAssertTrue(model.notice?.contains("已保存") == true)
        XCTAssertTrue(model.notice?.contains("不要重复提交") == true)
        XCTAssertTrue(model.requiresRefreshBeforeWrite)
        XCTAssertFalse(model.isWorking)
        await assertCode("RefreshRequired") {
            try await model.execute("重复新增", refresh: false) { _, _ in XCTFail("A repeated write must not run"); return true }
        }
        server.setReadFailure(nil)
        model.refresh()
        try await wait { !model.isWorking }
        XCTAssertFalse(model.requiresRefreshBeforeWrite)
    }

    func testUncertainWriteRequiresExplicitRefreshBeforeAnotherWrite() async throws {
        let model = try await loggedIn()
        await assertCode("ConnectionFailure") {
            try await model.execute("复制线路", refresh: false) { _, _ -> Bool in
                throw MapAPIError(code: "ConnectionFailure", message: "连接中断，结果未知")
            }
        }
        XCTAssertTrue(model.requiresRefreshBeforeWrite)
        await assertCode("RefreshRequired") {
            try await model.execute("复制线路", refresh: false) { _, _ in XCTFail("Do not retry an uncertain creation"); return true }
        }
        model.refresh()
        try await wait { !model.isWorking }
        XCTAssertFalse(model.requiresRefreshBeforeWrite)
        let saved = try await model.execute("编辑属性", refresh: false) { _, _ in true }
        XCTAssertTrue(saved)
    }

    func testConfirmedSaveThenExpiredRefreshStillReportsSavedOnLoginScreen() async throws {
        let model = try await loggedIn()
        server.setReadFailure("LoginExpired")
        let result = try await model.execute("新增线路") { _, _ in "saved-code" }
        XCTAssertEqual(result, "saved-code")
        XCTAssertNil(model.session)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.errorMessage?.contains("已保存") == true)
        XCTAssertTrue(model.notice?.contains("不要重复提交") == true)
        XCTAssertFalse(model.isWorking)
    }

    func testVersionConflictNeedsRefreshButDefinitePermissionFailureDoesNotBecomeUncertain() async throws {
        let model = try await loggedIn()
        await assertCode("NotOwner") {
            try await model.execute("编辑", refresh: false) { _, _ -> Bool in
                throw MapAPIError(code: "NotOwner", message: "没有权限")
            }
        }
        XCTAssertFalse(model.requiresRefreshBeforeWrite)
        await assertCode("VersionConflict") {
            try await model.execute("编辑", refresh: false) { _, _ -> Bool in
                throw MapAPIError(code: "VersionConflict", message: "线路已发生变化")
            }
        }
        XCTAssertTrue(model.requiresRefreshBeforeWrite)
        XCTAssertNotNil(model.snapshot)
    }

    func testBusyForegroundRejectsDoubleTapWithoutLaunchingSecondOperation() async throws {
        let model = try await loggedIn()
        let first = Task {
            try await model.execute("预览", mutation: false, refresh: false) { _, _ in
                try await Task.sleep(nanoseconds: 150_000_000)
                return "first"
            }
        }
        try await wait { model.isWorking }
        await assertCode("Busy") {
            try await model.execute("重复提交", refresh: false) { _, _ in XCTFail("Second tap should not run"); return "second" }
        }
        let result = try await first.value
        XCTAssertEqual(result, "first")
        XCTAssertFalse(model.isWorking)
    }

    func testLogoutAndReloginPreventOldOperationFromOverwritingCurrentSession() async throws {
        let model = try await loggedIn()
        let old = Task {
            try await model.execute("旧操作", refresh: false) { _, _ in
                // A server can finish committing despite a client-side cancellation.
                try? await Task.sleep(nanoseconds: 250_000_000)
                return "old-result"
            }
        }
        try await wait { model.isWorking }
        model.logout()
        model.userName = "second-editor"
        model.login(password: "fixture-secret")
        try await wait { !model.isWorking && model.session != nil }
        do { _ = try await old.value; XCTFail("An old generation cannot publish success into a new login") }
        catch is CancellationError { }
        XCTAssertEqual(model.session?.userName, "second-editor")
        XCTAssertEqual(model.snapshot?.lines.first?.owner, "second-editor")
        XCTAssertFalse(model.notice?.contains("旧操作") == true)
        XCTAssertFalse(model.requiresRefreshBeforeWrite)
    }

    func testExpiredMutationClearsSessionAndStopsCalculation() async throws {
        let model = try await loggedIn()
        model.startCalculation(.cross)
        await assertCode("LoginExpired") {
            try await model.execute("编辑", refresh: false) { _, _ -> Bool in
                throw MapAPIError(code: "LoginExpired", message: "会话已失效")
            }
        }
        XCTAssertNil(model.session)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isCalculating)
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.errorMessage?.contains("失效") == true)
    }

    func testUndoUncertainResponsePersistsIdAcrossReloginAndBlocksOtherWrites() async throws {
        let first = try await loggedIn()
        server.failUndoOnce()
        await assertCode("ConnectionFailure") { try await first.undoLastOperation() }
        XCTAssertTrue(first.hasPendingUndo)
        let originalID = try XCTUnwrap(server.undoIDs.first)
        XCTAssertEqual(originalID.count, 32)
        let stored = preferences.dictionaryRepresentation()
        XCTAssertFalse(stored.values.contains { String(describing: $0).contains("fixture-secret") })
        XCTAssertFalse(stored.values.contains { String(describing: $0).contains(MapVMFixtureServer.token) })
        first.logout()
        let second = try await loggedIn()
        XCTAssertTrue(second.hasPendingUndo)
        await assertCode("PendingUndo") {
            try await second.execute("新增", refresh: false) { _, _ in XCTFail("Pending undo must block a new mutation"); return true }
        }
        second.refresh()
        try await wait { !second.isWorking }
        XCTAssertTrue(second.hasPendingUndo)
        try await second.undoLastOperation()
        XCTAssertEqual(server.undoIDs, [originalID, originalID])
        XCTAssertFalse(second.hasPendingUndo)
        XCTAssertFalse(second.requiresRefreshBeforeWrite)
        XCTAssertTrue(second.notice?.contains("已撤销") == true)
    }

    func testDefiniteUndoRefusalClearsPendingId() async throws {
        let model = try await loggedIn()
        server.setUndoRefusal("NothingToUndo")
        await assertCode("NothingToUndo") { try await model.undoLastOperation() }
        XCTAssertFalse(model.hasPendingUndo)
        XCTAssertFalse(preferences.dictionaryRepresentation().keys.contains { $0.hasPrefix("map.pendingUndo.") })
    }

    func testBackgroundCalculationWaitsForForegroundAndCompletesIncrementally() async throws {
        let model = try await loggedIn()
        let foreground = Task {
            try await model.execute("预览", mutation: false, refresh: false) { _, _ in
                try await Task.sleep(nanoseconds: 150_000_000)
                return true
            }
        }
        try await wait { model.isWorking }
        model.startCalculation(.cross)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(server.crossCalls, 0)
        _ = try await foreground.value
        try await wait { !model.isCalculating }
        XCTAssertEqual(server.crossCalls, 2)
        XCTAssertTrue(model.calculationStatus?.contains("完成") == true)
        XCTAssertNotNil(model.snapshot)
    }

    func testLogicalCalculationRejectsNonAdvancingCursorInsteadOfLooping() async throws {
        let model = try await loggedIn()
        server.setRepeatedCursor(true)
        model.startCalculation(.logicalNodes)
        try await wait { !model.isCalculating }
        XCTAssertEqual(server.logicalCursors, ["<start>", "AAAAAAAAAA"])
        XCTAssertTrue(model.errorMessage?.contains("游标没有前进") == true)
        XCTAssertNotNil(model.snapshot)
    }

    func testStoppingQueuedCalculationSendsNoBackgroundTransactions() async throws {
        let model = try await loggedIn()
        let foreground = Task {
            try await model.execute("预览", mutation: false, refresh: false) { _, _ in
                try await Task.sleep(nanoseconds: 150_000_000)
                return true
            }
        }
        try await wait { model.isWorking }
        model.startCalculation(.cross)
        model.stopCalculation()
        _ = try await foreground.value
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(model.isCalculating)
        XCTAssertEqual(server.crossCalls, 0)
    }
}

private final class MapVMFixtureServer: @unchecked Sendable {
    static let token = "0123456789abcdef0123456789abcdef"
    private let lock = NSLock()
    private var readFailure: String?
    private var failNextUndo = false
    private var undoRefusal: String?
    private var repeatCursor = false
    private var recordedUndoIDs: [String] = []
    private var recordedCursors: [String] = []
    private var recordedCrossCalls = 0

    var undoIDs: [String] { lock.lock(); defer { lock.unlock() }; return recordedUndoIDs }
    var logicalCursors: [String] { lock.lock(); defer { lock.unlock() }; return recordedCursors }
    var crossCalls: Int { lock.lock(); defer { lock.unlock() }; return recordedCrossCalls }
    func setReadFailure(_ value: String?) { lock.lock(); defer { lock.unlock() }; readFailure = value }
    func failUndoOnce() { lock.lock(); defer { lock.unlock() }; failNextUndo = true }
    func setUndoRefusal(_ value: String) { lock.lock(); defer { lock.unlock() }; undoRefusal = value }
    func setRepeatedCursor(_ value: Bool) { lock.lock(); defer { lock.unlock() }; repeatCursor = value }

    func respond(to request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let body = try MapVMProtocol.body(request)
        let owner = body["userName"] as? String ?? body["owner"] as? String ?? "editor"
        let line: [String: Any] = ["code": "ZZZZZZZZZZ", "owner": owner, "version": 1, "isLocked": false,
                                 "nodes": [["lineCode": "ZZZZZZZZZZ", "order": 0, "x": 100, "y": 100],
                                           ["lineCode": "ZZZZZZZZZZ", "order": 1, "x": 110, "y": 100]]]
        let map: [String: Any] = ["lines": [line], "logicalNodes": [], "crosses": []]
        func success(_ data: Any) throws -> (Int, Data) {
            (200, try JSONSerialization.data(withJSONObject: ["success": true, "code": "Ok", "message": "完成", "data": data]))
        }
        func failure(_ code: String) throws -> (Int, Data) {
            (code == "LoginExpired" ? 401 : 200,
             try JSONSerialization.data(withJSONObject: ["success": false, "code": code, "message": code, "data": NSNull()]))
        }
        switch request.url?.lastPathComponent {
        case "Login": return (200, Data(Self.token.utf8))
        case "Logout": return try success(true)
        case "GetAllLineData":
            if let readFailure { return try failure(readFailure) }
            return try success([line])
        case "GetAllCrossData", "GetLogicalNodes": return try success([])
        case "UndoMap":
            recordedUndoIDs.append(body["requestId"] as? String ?? "missing")
            if failNextUndo { failNextUndo = false; throw URLError(.networkConnectionLost) }
            if let undoRefusal { return try failure(undoRefusal) }
            return try success(["operation": "编辑线路", "map": map])
        case "CalculateCross":
            recordedCrossCalls += 1
            return try success(["canContinue": recordedCrossCalls == 1, "remainingSegments": 0, "crossCount": 0])
        case "CalculateLogicalNode":
            recordedCursors.append(body["afterCode"] as? String ?? "<start>")
            let code = repeatCursor || recordedCursors.count == 1 ? "AAAAAAAAAA" : "BBBBBBBBBB"
            return try success(["canContinue": recordedCursors.count < 3, "remainingNodes": max(0, 3 - recordedCursors.count),
                                "nodeCount": 2, "nextCode": code])
        default: return try failure("UnexpectedEndpoint")
        }
    }
}

private final class MapVMProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?
    static func install(_ value: ((URLRequest) throws -> (Int, Data))?) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let respond = Self.handler; Self.lock.unlock()
        do {
            guard let respond else { throw URLError(.resourceUnavailable) }
            let (status, data) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
}
