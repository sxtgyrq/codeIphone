import Foundation
import XCTest
@testable import HelloYrq

/// These tests run under XCTest on an iOS simulator. Every URLSession request is
/// intercepted; no real Server, database, account or local-network permission is used.
final class MapAPITests: XCTestCase {
    private var transport: URLSession!
    private let server = URL(string: "https://192.168.1.20:61011/")!
    private let firstToken = "0123456789abcdef0123456789abcdef"
    private let secondToken = "fedcba9876543210fedcba9876543210"

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapStubURLProtocol.self]
        configuration.urlCache = nil
        transport = URLSession(configuration: configuration)
    }

    override func tearDown() {
        transport.invalidateAndCancel()
        transport = nil
        MapStubURLProtocol.install(nil)
        super.tearDown()
    }

    private var api: MapAPI { MapAPI(serverURL: server, session: transport) }
    private var account: MapSession { MapSession(userName: "测试用户", loginCode: firstToken) }

    private func script(_ steps: [MapHTTPScenario.Step]) -> MapHTTPScenario {
        let scenario = MapHTTPScenario(steps)
        MapStubURLProtocol.install { try scenario.respond(to: $0) }
        return scenario
    }

    private func assertError(_ code: String, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as MapAPIError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testLoginReadLogoutAndReloginScriptUsesOnlyCurrentSessionAndReadEndpoints() async throws {
        let scenario = script([
            .init("Login", "\n\(firstToken)\n", contentType: "text/plain"),
            .init("GetAllLineData", envelope("[\(Self.lineJSON)]")),
            .init("GetAllCrossData", envelope("[\(Self.crossJSON)]")),
            .init("GetLogicalNodes", envelope("[\(Self.nodeJSON)]")),
            .init("Logout", envelope("true")),
            .init("Login", secondToken, contentType: "text/plain"),
            .init("GetAllLineData", #"{"success":false,"code":"LoginExpired","message":"会话已过期","data":null}"#, status: 401)
        ])
        let loggedIn = try await api.login(userName: "  测试用户  ", password: " mock-only-password ")
        XCTAssertEqual(loggedIn, account)
        let map = try await api.loadMap(session: loggedIn)
        XCTAssertEqual(map.lines.count, 1)
        XCTAssertEqual(map.lines[0].properties.roadName, "测试线路😀")
        XCTAssertEqual(map.crosses[0].x, 110)
        XCTAssertEqual(map.crosses[0].state, 2)
        XCTAssertTrue(map.crosses[0].canTransfer)
        XCTAssertEqual(map.logicalNodes[0].x, 110.5)
        XCTAssertEqual(map.logicalNodes[0].properties.logicLanguage, "¬(?)")
        XCTAssertEqual(map.logicalNodes[0].positions[0].roadPercent, 0.5125, accuracy: 1e-15)
        try await api.logout(session: loggedIn)
        let reloggedIn = try await api.login(userName: "测试用户", password: "another-mock-password")
        XCTAssertEqual(reloggedIn.loginCode, secondToken)
        await assertError("LoginExpired") { _ = try await self.api.loadMap(session: reloggedIn) }
        XCTAssertEqual(scenario.remainingCount, 0)
        let requests = scenario.requests
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent },
                       ["Login", "GetAllLineData", "GetAllCrossData", "GetLogicalNodes", "Logout", "Login", "GetAllLineData"])
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
            let body = try MapHTTPScenario.body(request)
            XCTAssertEqual(body["userName"] as? String, "测试用户")
            if request.url!.lastPathComponent == "Login" {
                XCTAssertEqual(Set(body.keys), ["userName", "password", "dbPrefix"])
                XCTAssertEqual(body["dbPrefix"] as? String, "ArgumentMap")
                XCTAssertEqual(body["password"] as? String, index == 0 ? " mock-only-password " : "another-mock-password")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/plain")
            } else {
                XCTAssertEqual(Set(body.keys), ["userName", "loginCode"])
                XCTAssertEqual(body["loginCode"] as? String, index == 6 ? secondToken : firstToken)
            }
        }
    }

    func testLoginRejectsEmptyQuotedJSONAndMalformedTokens() async {
        for (reply, code) in [("", "InvalidCredentials"), ("   \n", "InvalidCredentials"),
                              ("\"\(firstToken)\"", "InvalidResponse"),
                              (envelope("\"\(firstToken)\""), "InvalidResponse"),
                              (String(repeating: "G", count: 32), "InvalidResponse"),
                              (String(repeating: "a", count: 31), "InvalidResponse")] {
            let scenario = script([.init("Login", reply, contentType: "text/plain")])
            await assertError(code) { _ = try await self.api.login(userName: "owner", password: "mock-password") }
            XCTAssertEqual(scenario.remainingCount, 0)
        }
    }

    func testSessionExpiredHTTPAndBusinessResponsesStopFurtherMapReads() async {
        for (status, body) in [(401, "Not authorized"),
                               (200, #"{"success":false,"code":"LoginExpired","message":"另一设备已登录","data":{"unexpected":true}}"#)] {
            let scenario = script([.init("GetAllLineData", body, status: status)])
            do {
                _ = try await api.loadMap(session: account)
                XCTFail("Expired session must fail.")
            } catch let error as MapAPIError {
                XCTAssertTrue(error.isSessionExpired)
                if status == 200 { XCTAssertEqual(error.message, "另一设备已登录") }
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(scenario.requests.count, 1)
        }
    }

    func testSuccessWithMissingOrNullDataFailsAtEachReadBoundary() async {
        let paths = ["GetAllLineData", "GetAllCrossData", "GetLogicalNodes"]
        for position in paths.indices {
            for invalid in [#"{"success":true,"code":"OK","message":"ok"}"#,
                            #"{"success":true,"code":"OK","message":"ok","data":null}"#] {
                var steps = paths.prefix(position).map { MapHTTPScenario.Step($0, envelope("[]")) }
                steps.append(.init(paths[position], invalid))
                let scenario = script(steps)
                await assertError("InvalidResponse") { _ = try await self.api.loadMap(session: self.account) }
                XCTAssertEqual(scenario.requests.count, position + 1)
                XCTAssertEqual(scenario.remainingCount, 0)
            }
        }
    }

    func testHalfIntegerCrossFailsWholeReadWithoutFetchingLogicalNodes() async {
        let half = Self.crossJSON.replacingOccurrences(of: #""x2":220"#, with: #""x2":221"#)
        let scenario = script([.init("GetAllLineData", envelope("[\(Self.lineJSON)]")),
                               .init("GetAllCrossData", envelope("[\(half)]"))])
        await assertError("InvalidResponse") { _ = try await self.api.loadMap(session: self.account) }
        XCTAssertEqual(scenario.requests.count, 2)
        XCTAssertEqual(scenario.remainingCount, 0)
    }

    func testDuplicateIdentitiesDoNotProduceAmbiguousMapSnapshot() async {
        let scenario = script([.init("GetAllLineData", envelope("[\(Self.lineJSON),\(Self.lineJSON)]")),
                               .init("GetAllCrossData", envelope("[]")), .init("GetLogicalNodes", envelope("[]"))])
        await assertError("InvalidResponse") { _ = try await self.api.loadMap(session: self.account) }
        XCTAssertEqual(scenario.remainingCount, 0)
    }

    func testInvalidLineCoordinatesOwnershipAndOrderRejectMapBeforeDisplay() async {
        let invalidLines = [
            Self.lineJSON.replacingOccurrences(of: #""x":90"#, with: #""x":-1"#),
            Self.lineJSON.replacingOccurrences(of: #""x":130"#, with: #""x":500001"#),
            Self.lineJSON.replacingOccurrences(of: #""y":110"#, with: #""y":500001"#),
            Self.lineJSON.replacingOccurrences(of: #""lineCode":"ZZZZZZZZZZ""#, with: #""lineCode":"AAAAAAAAAA""#),
            Self.lineJSON.replacingOccurrences(of: #""order":0"#, with: #""order":1"#),
            Self.lineJSON.replacingOccurrences(of: #""order":1"#, with: #""order":2"#)
        ]
        for invalid in invalidLines {
            let scenario = script([.init("GetAllLineData", envelope("[\(invalid)]")),
                                   .init("GetAllCrossData", envelope("[]")), .init("GetLogicalNodes", envelope("[]"))])
            await assertError("InvalidResponse") { _ = try await self.api.loadMap(session: self.account) }
            XCTAssertEqual(scenario.remainingCount, 0)
        }
    }

    func testInvalidLogicalNodeCentersSizeAndFullBoundsRejectMapBeforeDisplay() async {
        let invalidNodes = [
            Self.nodeJSON.replacingOccurrences(of: #""x":110.5"#, with: #""x":110"#),
            Self.nodeJSON.replacingOccurrences(of: #""y":110.5"#, with: #""y":110.25"#),
            Self.nodeJSON.replacingOccurrences(of: #""x":110.5"#, with: #""x":-0.5"#),
            Self.nodeJSON.replacingOccurrences(of: #""x":110.5"#, with: #""x":500000.5"#),
            Self.nodeJSON.replacingOccurrences(of: #""x":110.5"#, with: #""x":2.5"#),
            Self.nodeJSON.replacingOccurrences(of: #""y":110.5"#, with: #""y":499997.5"#),
            Self.nodeJSON.replacingOccurrences(of: #""sideLength":8"#, with: #""sideLength":0"#),
            Self.nodeJSON.replacingOccurrences(of: #""sideLength":8"#, with: #""sideLength":7"#),
            Self.nodeJSON.replacingOccurrences(of: #""sideLength":8"#, with: #""sideLength":20"#)
        ]
        for invalid in invalidNodes {
            let scenario = script([.init("GetAllLineData", envelope("[]")), .init("GetAllCrossData", envelope("[]")),
                                   .init("GetLogicalNodes", envelope("[\(invalid)]"))])
            await assertError("InvalidResponse") { _ = try await self.api.loadMap(session: self.account) }
            XCTAssertEqual(scenario.remainingCount, 0)
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(MapLogicalNode(code: "BBBBBBBBBB", owner: "owner", version: 1,
                                          x: invalid, y: 110.5, sideLength: 8).isValidGeometry)
            XCTAssertFalse(MapLogicalNode(code: "BBBBBBBBBB", owner: "owner", version: 1,
                                          x: 110.5, y: invalid, sideLength: 8).isValidGeometry)
        }
    }

    func testEmptyDraftLineAndAllNodeSizesKeepLegacyTextCompatible() async throws {
        let draft = #"{"code":"ZZZZZZZZZZ","owner":"测试用户","isLocked":false,"version":1,"nodes":[],"properties":{"roadName":"旧线路"}}"#
        for size in [4, 6, 8, 10, 12, 18] {
            let node = Self.nodeJSON.replacingOccurrences(of: #""sideLength":8"#, with: "\"sideLength\":\(size)")
                .replacingOccurrences(of: #""value":"¬""#, with: #""value":"历史文本保留""#)
                .replacingOccurrences(of: #""logicLanguage":"¬(?)""#, with: #""logicLanguage":"旧逻辑语言""#)
            let scenario = script([.init("GetAllLineData", envelope("[\(draft)]")), .init("GetAllCrossData", envelope("[]")),
                                   .init("GetLogicalNodes", envelope("[\(node)]"))])
            let map = try await api.loadMap(session: account)
            XCTAssertTrue(map.lines[0].nodes.isEmpty)
            XCTAssertEqual(map.logicalNodes[0].sideLength, size)
            XCTAssertEqual(map.logicalNodes[0].properties.value, "历史文本保留")
            XCTAssertEqual(map.logicalNodes[0].properties.logicLanguage, "旧逻辑语言")
            XCTAssertEqual(scenario.remainingCount, 0)
        }
    }

    func testBusinessErrorIsDecodedBeforeItsUnexpectedDataShape() async {
        let scenario = script([.init("Logout", #"{"success":false,"code":"MapBusy","message":"稍后重试","data":[1,2]}"#)])
        do { try await api.logout(session: account); XCTFail("Expected business error.") }
        catch let error as MapAPIError { XCTAssertEqual(error, MapAPIError(code: "MapBusy", message: "稍后重试")) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(scenario.remainingCount, 0)
    }

    func testLogoutRequiresTrueDataAndNetworkErrorsHaveDistinctMessages() async {
        for data in ["false", "null"] {
            _ = script([.init("Logout", envelope(data))])
            await assertError("InvalidResponse") { try await self.api.logout(session: self.account) }
        }
        for (failure, code) in [(URLError.Code.notConnectedToInternet, "ConnectionFailure"),
                                (.appTransportSecurityRequiresSecureConnection, "SecureConnectionRequired")] {
            MapStubURLProtocol.install { _ in throw URLError(failure) }
            await assertError(code) { _ = try await self.api.login(userName: "owner", password: "mock-password") }
        }
    }

    func testCancellationIsNotReportedAsBadCredentialsOrConnectionFailure() async {
        MapStubURLProtocol.install { _ in throw URLError(.cancelled) }
        do { _ = try await api.login(userName: "owner", password: "mock-password"); XCTFail("Expected cancellation.") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation was changed to \(error)") }
    }

    func testServerURLNormalizationRejectsPhoneLoopbackAndCredentialURLs() throws {
        XCTAssertEqual(try MapAPI.normalizedURL(" http://192.168.1.20:61011 ").absoluteString, "http://192.168.1.20:61011/")
        XCTAssertEqual(try MapAPI.normalizedURL("https://example.com/maps").absoluteString, "https://example.com/maps/")
        for invalid in ["192.168.1.20:61011", "ftp://example.com", "http://localhost:61011", "http://127.0.0.1:61011",
                        "http://[::1]:61011", "http://0.0.0.0:61011", "http://[::]:61011", "http://u:p@example.com", "https://example.com?q=1", "https://example.com/#map"] {
            XCTAssertThrowsError(try MapAPI.normalizedURL(invalid), invalid)
        }
        XCTAssertEqual(try MapAPI.normalizedURL("http://127.0.0.1:61011", allowLoopback: true).host, "127.0.0.1")
    }

    func testModelDecodingPreservesHalfNodeCoordinatesButRejectsInvalidCrossIdentity() throws {
        let decoder = JSONDecoder()
        let node = try decoder.decode(MapLogicalNode.self, from: Data(Self.nodeJSON.utf8))
        XCTAssertEqual(node.x, 110.5)
        XCTAssertEqual(node.sideLength, 8)
        XCTAssertEqual(node.canEdit, false)
        let minimal = #"{"code":"BBBBBBBBBB","owner":"owner","version":1,"x":110.5,"y":110.5,"sideLength":8}"#
        let defaults = try decoder.decode(MapLogicalNode.self, from: Data(minimal.utf8))
        XCTAssertTrue(defaults.positions.isEmpty)
        XCTAssertNil(defaults.canEdit)
        for (original, replacement) in [(#""x2":220"#, #""x2":221"#), (#""y2":220"#, #""y2":1000002"#),
                                         (#""roadCode1":"ZZZZZZZZZZ""#, #""roadCode1":"AAAAAAAAAA""#),
                                         (#""state":2"#, #""state":4"#), (#""percent1":0.5"#, #""percent1":1.1"#)] {
            XCTAssertThrowsError(try decoder.decode(MapCross.self, from: Data(Self.crossJSON.replacingOccurrences(of: original, with: replacement).utf8)))
        }
        XCTAssertThrowsError(try decoder.decode(MapLine.self, from: Data(#"{"code":"AAAAAAAAAA","owner":"owner","version":1,"isLocked":false}"#.utf8)))
    }

    private func envelope(_ data: String) -> String { "{\"success\":true,\"code\":\"OK\",\"message\":\"ok\",\"data\":\(data)}" }
    private static let lineJSON = #"{"code":"ZZZZZZZZZZ","owner":"测试用户","isLocked":false,"version":3,"nodes":[{"lineCode":"ZZZZZZZZZZ","order":0,"x":90,"y":110},{"lineCode":"ZZZZZZZZZZ","order":1,"x":130,"y":110}],"properties":{"roadName":"测试线路😀","roadDetail":"只读","speed":100,"passInDirection":1,"passInOpposeDirection":0}}"#
    private static let crossJSON = #"{"key":{"roadCode1":"ZZZZZZZZZZ","roadCode2":"AAAAAAAAAA","position":{"x2":220,"y2":220,"x":110,"y":110,"isInteger":true},"isValid":true},"roadOrder1":0,"roadOrder2":1,"roadVersion1":3,"roadVersion2":7,"state":2,"version":9,"percent1":0.5,"percent2":0.25,"stateLabel":"计算属性","canTransfer":true}"#
    private static let nodeJSON = #"{"code":"BBBBBBBBBB","owner":"测试用户","version":2,"x":110.5,"y":110.5,"sideLength":8,"properties":{"value":"¬","info":"说明","logicLanguage":"¬(?)","operandKind":"Custom"},"positions":[{"logicalNodeCode":"BBBBBBBBBB","roadCode":"ZZZZZZZZZZ","roadOrder":0,"roadPercent":0.5125,"x":110.5,"y":110,"roadVersion":3,"isChanged":false}],"canEdit":false,"isStart":false,"left":106.5}"#
}

private final class MapHTTPScenario {
    struct Step {
        let path: String
        let body: String
        let status: Int
        let contentType: String
        init(_ path: String, _ body: String, status: Int = 200, contentType: String = "application/json") {
            self.path = path; self.body = body; self.status = status; self.contentType = contentType
        }
    }
    private let lock = NSLock()
    private var pending: [Step]
    private var recorded: [URLRequest] = []
    init(_ steps: [Step]) { pending = steps }
    var remainingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock(); defer { lock.unlock() }
        // Capture the body before URLSession's one-shot stream is consumed.
        var captured = request
        captured.httpBody = try Self.bytes(request)
        recorded.append(captured)
        guard !pending.isEmpty else { throw URLError(.badServerResponse) }
        let step = pending.removeFirst()
        XCTAssertEqual(request.url?.lastPathComponent, step.path)
        let response = HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": step.contentType])!
        return (response, Data(step.body.utf8))
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes(request)) as? [String: Any])
    }
    private static func bytes(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class MapStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static func install(_ value: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
