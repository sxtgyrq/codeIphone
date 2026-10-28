#if DEBUG
import Foundation

// Compiled only for Debug. Activated only by the native UI test launch argument;
// normal launches always use the real Server and never display fixture data.
enum MapUITestSupport {
    @MainActor
    static func makeModel() -> MapViewModel {
        let defaults = UserDefaults(suiteName: "ArgumentMap.UITests")!
        defaults.removePersistentDomain(forName: "ArgumentMap.UITests")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MapUITestProtocol.self]
        let session = URLSession(configuration: configuration)
        return MapViewModel(defaults: defaults, makeAPI: { MapAPI(serverURL: $0, session: session) })
    }
}

private final class MapUITestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var lineReads = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.lastPathComponent
        let scenario = ProcessInfo.processInfo.environment["MAP_UI_SCENARIO"] ?? "success"
        if scenario == "unreachable" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if path == "Login" {
            let text = scenario == "invalid-login" ? "" : "0123456789abcdef0123456789abcdef"
            reply(Data(text.utf8), status: 200, contentType: "text/plain")
            return
        }
        if path == "GetAllLineData" {
            Self.lock.lock()
            Self.lineReads += 1
            let read = Self.lineReads
            Self.lock.unlock()
            if scenario == "expired" && read > 1 {
                envelope(success: false, data: NSNull(), status: 401, code: "LoginExpired", message: "登录已失效，请重新登录。")
                return
            }
            if scenario == "refresh-failure" && read > 1 {
                envelope(success: false, data: NSNull(), status: 500, code: "DatabaseError", message: "服务暂时不可用。")
                return
            }
        }
        let empty = scenario == "empty"
        let unitDetail = scenario == "unit-detail"
        switch path {
        case "GetAllLineData": envelope(data: empty ? [] : unitDetail ? Self.unitLines : Self.lines)
        case "GetAllCrossData": envelope(data: empty || unitDetail ? [] : Self.crosses)
        case "GetLogicalNodes":
            Self.lock.lock(); let reads = Self.lineReads; Self.lock.unlock()
            var result = empty || unitDetail ? [] : Self.nodes
            if scenario == "success" && reads > 1 {
                result.append(["code": "IIIIIIIIII", "owner": "demo", "version": 1,
                               "x": 300.5, "y": 160.5, "sideLength": 12,
                               "properties": ["value": "刷新新增", "info": "", "logicLanguage": "第二次读取", "operandKind": "Custom"],
                               "positions": [], "canEdit": true])
            }
            envelope(data: result)
        case "Logout": envelope(data: true)
        default: envelope(success: false, data: NSNull(), status: 404, code: "UnexpectedEndpoint", message: "Unexpected test request")
        }
    }

    private func envelope(success: Bool = true, data: Any, status: Int = 200, code: String = "Ok", message: String = "已加载") {
        let value: [String: Any] = ["success": success, "code": code, "message": message, "data": data]
        reply(try! JSONSerialization.data(withJSONObject: value), status: status, contentType: "application/json")
    }

    private func reply(_ data: Data, status: Int, contentType: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func line(_ code: String, points: [[Int]], reverse: Int) -> [String: Any] {
        let vertices = points.enumerated().map { index, xy -> [String: Any] in
            ["lineCode": code, "order": index, "x": xy[0], "y": xy[1]]
        }
        return ["code": code, "owner": "demo", "isLocked": false, "version": 1, "nodes": vertices,
                "properties": ["roadName": "示例线路", "roadDetail": "UI 测试", "speed": 100, "passInDirection": 1, "passInOpposeDirection": reverse]]
    }

    private static var lines: [[String: Any]] {
        [line("BBBBBBBBBB", points: [[80,110],[275,110]], reverse: 0),
         line("AAAAAAAAAA", points: [[225,90],[225,135]], reverse: 1)]
    }

    private static var unitLines: [[String: Any]] {
        [line("BBBBBBBBBB", points: [[100,100],[101,100]], reverse: 0),
         line("AAAAAAAAAA", points: [[102,100],[102,101]], reverse: 0),
         line("CCCCCCCCCC", points: [[100,101],[101,102]], reverse: 0)]
    }

    private static var crosses: [[String: Any]] {
        [["key": ["roadCode1": "BBBBBBBBBB", "roadCode2": "AAAAAAAAAA", "position": ["x2": 450, "y2": 220]],
          "roadOrder1": 0, "roadOrder2": 0, "roadVersion1": 1, "roadVersion2": 1,
          "state": 1, "version": 1, "percent1": 0.743589743589744, "percent2": 0.444444444444444]]
    }

    private static var nodes: [[String: Any]] {
        let definitions: [(String, Int, Double, String, String)] = [
            ("CCCCCCCCCC",4,100.5,"True","示例命题"),
            ("DDDDDDDDDD",8,125.5,"¬","¬(?)"),
            ("EEEEEEEEEE",6,150.5,"命题","示例命题"),
            ("FFFFFFFFFF",10,180.5,"human(name=Alice)","human(name=Alice)∈HUMAN"),
            ("GGGGGGGGGG",12,210.5,"HUMAN","人类"),
            ("HHHHHHHHHH",18,250.5,"开始","从这里开始")]
        return definitions.map { item -> [String: Any] in
            ["code": item.0, "owner": "demo", "version": 1, "x": item.2, "y": 110.5, "sideLength": item.1,
             "properties": ["value": item.3, "info": "仅用于原生 UI 测试", "logicLanguage": item.4, "operandKind": "Custom"],
             "positions": [], "canEdit": true]
        }
    }
}
#endif
