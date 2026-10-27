import Foundation
import Combine

@MainActor
final class MapViewModel: ObservableObject {
    @Published var serverAddress: String
    @Published var userName: String
    @Published private(set) var session: MapSession?
    @Published private(set) var snapshot: MapSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    private let defaults: UserDefaults
    private let makeAPI: (URL) -> MapAPI
    private var api: MapAPI?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, makeAPI: @escaping (URL) -> MapAPI = { MapAPI(serverURL: $0) }) {
        self.defaults = defaults
        self.makeAPI = makeAPI
        serverAddress = defaults.string(forKey: "map.serverAddress") ?? ""
        userName = defaults.string(forKey: "map.userName") ?? ""
    }

    static func applicationModel() -> MapViewModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return MapUITestSupport.makeModel()
        }
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
            let requestID = UUID()
            generation = requestID
            isWorking = true
            errorMessage = nil
            work = Task { [weak self] in
                guard let self = self else { return }
                defer { if self.generation == requestID { self.isWorking = false } }
                do {
                    let account = try await candidate.login(userName: name, password: password)
                    guard !Task.isCancelled, self.generation == requestID else { return }
                    self.api = candidate
                    self.session = account
                    self.userName = name
                    self.serverAddress = url.absoluteString
                    // Only connection preferences are saved. Password and LoginCode stay in memory.
                    self.defaults.set(url.absoluteString, forKey: "map.serverAddress")
                    self.defaults.set(name, forKey: "map.userName")
                    let map = try await candidate.loadMap(session: account)
                    guard !Task.isCancelled, self.generation == requestID else { return }
                    self.snapshot = map
                    self.lastRefresh = Date()
                } catch {
                    self.handle(error, requestID: requestID)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        guard !isWorking, let account = session, let client = api else { return }
        let requestID = UUID()
        generation = requestID
        isWorking = true
        errorMessage = nil
        work = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.generation == requestID { self.isWorking = false } }
            do {
                let map = try await client.loadMap(session: account)
                guard !Task.isCancelled, self.generation == requestID else { return }
                // Publish all three collections together, retaining the previous map on failure.
                self.snapshot = map
                self.lastRefresh = Date()
            } catch {
                self.handle(error, requestID: requestID)
            }
        }
    }

    func logout() {
        let previousSession = session
        let previousAPI = api
        generation = UUID()
        work?.cancel()
        work = nil
        session = nil
        snapshot = nil
        api = nil
        lastRefresh = nil
        isWorking = false
        errorMessage = nil
        if let account = previousSession, let client = previousAPI {
            // Clearing the local session must not wait for a disconnected computer.
            Task { try? await client.logout(session: account) }
        }
    }

    private func handle(_ error: Error, requestID: UUID) {
        guard generation == requestID, !Task.isCancelled else { return }
        if let serviceError = error as? MapAPIError, serviceError.isSessionExpired {
            session = nil
            snapshot = nil
            api = nil
            lastRefresh = nil
        }
        errorMessage = error.localizedDescription
    }
}
