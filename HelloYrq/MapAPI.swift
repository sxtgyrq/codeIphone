import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MapAPIError: LocalizedError, Equatable, Sendable {
    let code: String
    let message: String

    var errorDescription: String? {
        var text = message
        for (desktop, touch) in [("按 F6", "点击“保存线路”"), ("按 F4", "点击“刷新”"),
                                  ("按 F3", "点击“刷新”"), ("按 F2", "点击“刷新”"),
                                  ("按 K", "点击“计算交点”"), ("按 J", "点击“重算 LN 关联”")] {
            text = text.replacingOccurrences(of: desktop, with: touch)
        }
        return text
    }
    var isSessionExpired: Bool { code == "LoginExpired" }
}

/// The phone reads the existing Server API. No database credentials or password storage belong here.
struct MapAPI {
    let serverURL: URL
    private let session: URLSession

    init(serverURL: URL, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.session = session
    }

    static func normalizedURL(_ raw: String, allowLoopback: Bool = false) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || (1...65_535).contains(components.port!) else {
            throw MapAPIError(code: "InvalidServerURL", message: "请输入完整的 Server 地址，例如 http://192.168.1.20:61011/，不要包含账号、密码或查询参数。")
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !["0.0.0.0", "::", "0:0:0:0:0:0:0:0"].contains(host) else {
            throw MapAPIError(code: "InvalidServerURL", message: "0.0.0.0 和 :: 是监听地址。请填写运行 Server 的电脑局域网 IP。")
        }
        let localHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let isLoopback = localHost == "localhost" || localHost.hasSuffix(".localhost") ||
            localHost.hasPrefix("127.") || localHost == "::1" || localHost == "0:0:0:0:0:0:0:1" ||
            localHost.hasPrefix("::ffff:127.") || localHost == "2130706433"
        guard allowLoopback || !isLoopback else {
            throw MapAPIError(code: "LoopbackServerURL", message: "localhost 和 127.0.0.1 在 iPhone 上指向手机自身。请填写运行 Server 的电脑局域网 IP，并连接同一 Wi-Fi。")
        }
        components.scheme = scheme
        // Retain an explicitly configured reverse-proxy base path.
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let url = components.url else {
            throw MapAPIError(code: "InvalidServerURL", message: "Server 地址格式无效。")
        }
        return url
    }

    func login(userName: String, password: String) async throws -> MapSession {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MapAPIError(code: "InvalidCredentials", message: "请输入用户名和密码。")
        }
        let (data, response) = try await send("Login", body: LoginBody(userName: name, password: password))
        try checkStatus(response, data: data)
        guard let text = String(data: data, encoding: .utf8) else { throw invalidResponse() }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw MapAPIError(code: "InvalidCredentials", message: "用户名或密码错误。")
        }
        guard token.utf8.count == 32, token.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw invalidResponse() }
        return MapSession(userName: name, loginCode: token)
    }

    func loadMap(session mapSession: MapSession) async throws -> MapSnapshot {
        // Publish only after all three reads succeed; an expired session must not
        // replace a complete displayed map with a partial result.
        let lines: [MapLine] = try await post("GetAllLineData", body: mapSession)
        try Task.checkCancellation()
        let crosses: [MapCross] = try await post("GetAllCrossData", body: mapSession)
        try Task.checkCancellation()
        let nodes: [MapLogicalNode] = try await post("GetLogicalNodes", body: mapSession)
        guard Set(lines.map(\.code)).count == lines.count,
              Set(nodes.map(\.code)).count == nodes.count,
              Set(crosses.map(\.key)).count == crosses.count,
              lines.allSatisfy(\.isValidGeometry), nodes.allSatisfy(\.isValidGeometry) else { throw invalidResponse() }
        // The server reads are separate transactions. Do not reject a concurrent
        // map edit merely because a returned Cross's road is absent in another read.
        return MapSnapshot(lines: lines, logicalNodes: nodes, crosses: crosses)
    }

    func logout(session mapSession: MapSession) async throws {
        let loggedOut: Bool = try await post("Logout", body: mapSession)
        guard loggedOut else { throw invalidResponse() }
    }

    private struct LoginBody: Encodable {
        let userName: String
        let password: String
        let dbPrefix = "ArgumentMap"
    }

    private struct ResponseStatus: Decodable {
        let success: Bool
        let code: String?
        let message: String?
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let success: Bool
        let code: String?
        let message: String?
        let data: Value?
    }

    func post<Body: Encodable, Value: Decodable>(_ path: String, body: Body, timeoutInterval: TimeInterval = 30) async throws -> Value {
        let (data, response) = try await send(path, body: body, timeoutInterval: timeoutInterval)
        try checkStatus(response, data: data)
        let decoder = JSONDecoder()
        // Decode business errors before the typed payload: failure data may be null
        // or a different shape, including on endpoints that normally return Bool.
        guard let status = try? decoder.decode(ResponseStatus.self, from: data) else { throw invalidResponse() }
        guard status.success else {
            throw MapAPIError(code: status.code ?? "ServerError", message: status.message ?? "Server 未能完成请求。")
        }
        do {
            let result = try decoder.decode(Envelope<Value>.self, from: data)
            guard let value = result.data else { throw invalidResponse() }
            return value
        } catch let error as MapAPIError {
            throw error
        } catch {
            throw invalidResponse()
        }
    }

    private func checkStatus(_ response: HTTPURLResponse, data: Data) throws {
        let status = try? JSONDecoder().decode(ResponseStatus.self, from: data)
        if response.statusCode == 401 {
            throw MapAPIError(code: "LoginExpired", message: status?.message ?? "登录已失效，请重新登录。另一台设备使用同一账号登录也会使本次登录失效。")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MapAPIError(code: status?.code ?? "HttpError",
                              message: status?.message ?? "Server 请求失败（HTTP \(response.statusCode)），请检查服务地址和 Server 状态。")
        }
    }

    private func send<Body: Encodable>(_ path: String, body: Body, timeoutInterval: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(path == "Login" ? "text/plain" : "application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw invalidResponse() }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MapAPIError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .appTransportSecurityRequiresSecureConnection {
                throw MapAPIError(code: "SecureConnectionRequired", message: "该地址需要 HTTPS。请使用电脑的局域网 IP，或为 Server 配置 HTTPS。")
            }
            throw MapAPIError(code: "ConnectionFailure", message: "无法连接 Server。请确认手机与电脑处于同一 Wi-Fi，Server 已启动，并允许局域网访问该端口。")
        } catch {
            throw MapAPIError(code: "ConnectionFailure", message: "无法完成 Server 请求，请检查网络后重试。")
        }
    }

    private func invalidResponse() -> MapAPIError {
        MapAPIError(code: "InvalidResponse", message: "Server 返回的地图数据格式无效或版本不兼容，请确认使用最新版 ArgumentMap Server 后刷新。")
    }
}
