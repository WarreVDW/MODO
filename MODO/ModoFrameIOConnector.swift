import Foundation
import AppKit
import Network
import CryptoKit
import Security

/// Frame.io V4 connector for MODO.
///
/// Authentication uses Adobe IMS OAuth Native App credentials with PKCE. No
/// client secret is embedded in the app. Tokens are profile-scoped in Keychain.
@MainActor
final class ModoFrameIOConnector: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(String)
        case working(String)
        case error(String)

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected(let name): return name.isEmpty ? "Connected" : name
            case .working(let message): return message
            case .error(let message): return message
            }
        }
    }

    struct ProjectRef: Identifiable, Hashable {
        var id: String
        var name: String
        var accountID: String
        var accountName: String
        var workspaceID: String
        var workspaceName: String
        var rootFolderID: String?
        var webURL: String?

        var pathLabel: String {
            [accountName, workspaceName].filter { !$0.isEmpty }.joined(separator: " / ")
        }
    }

    private struct Credential: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var displayName: String
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double
    }

    private struct Resource {
        var id: String
        var name: String
        var webURL: String?
        var rootFolderID: String?
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var accountName = ""
    @Published private(set) var projects: [ProjectRef] = []
    @Published private(set) var lastCatalogRefresh: Date?

    private weak var store: FramoStudioStore?
    private var credential: Credential?

    func install(store: FramoStudioStore) {
        self.store = store
        loadCredential()
        if isConnected {
            Task { await refreshCatalog(silent: true) }
        }
    }

    func reloadForActiveProfile() {
        projects = []
        lastCatalogRefresh = nil
        loadCredential()
        if isConnected {
            Task { await refreshCatalog(silent: true) }
        }
    }

    var isConnected: Bool { credential != nil }

    var effectiveClientID: String? {
        if let configured = store?.settings.frameIOOAuthClientID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty { return configured }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "MODOFrameIOOAuthClientID") as? String {
            let value = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.contains("$(") { return value }
        }
        return nil
    }

    func connect() {
        guard state != .connecting else { return }
        guard let clientID = effectiveClientID else {
            state = .error("Add an Adobe/Frame.io OAuth Native App client ID first")
            return
        }
        state = .connecting
        Task {
            do {
                let receiver = try await ModoFrameIOOAuthLoopbackReceiver.start()
                let verifier = Self.pkceVerifier()
                let challenge = Self.pkceChallenge(verifier)
                let stateToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let scopes = store?.settings.effectiveFrameIOOAuthScopes ?? "openid,email,profile"

                var components = URLComponents(string: "https://ims-na1.adobelogin.com/ims/authorize/v2")!
                components.queryItems = [
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "redirect_uri", value: receiver.redirectURI),
                    URLQueryItem(name: "scope", value: scopes),
                    URLQueryItem(name: "state", value: stateToken),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256")
                ]
                guard let url = components.url else { throw ConnectorError.invalidResponse }
                NSWorkspace.shared.open(url)

                let callback = try await receiver.waitForCallback()
                guard callback.state == stateToken else { throw ConnectorError.stateMismatch }
                guard let code = callback.code else { throw ConnectorError.oauthDenied(callback.error ?? "Authorization was cancelled") }
                let token = try await exchangeCode(code, verifier: verifier, clientID: clientID)
                let displayName = (try? await fetchCurrentUserName(accessToken: token.access_token)) ?? "Frame.io"
                let saved = Credential(
                    accessToken: token.access_token,
                    refreshToken: token.refresh_token,
                    expiresAt: .now.addingTimeInterval(max(60, token.expires_in - 60)),
                    displayName: displayName
                )
                credential = saved
                accountName = displayName
                saveCredential(saved)
                state = .connected(displayName)
                await refreshCatalog(silent: true)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        guard let profileID = store?.activeProfileID else { return }
        FramoV5Keychain.clearFrameIOCredential(profileID: profileID)
        credential = nil
        accountName = ""
        projects = []
        lastCatalogRefresh = nil
        state = .disconnected
    }

    func refreshCatalog(silent: Bool = false) async {
        guard isConnected else { return }
        if !silent { state = .working("Loading Frame.io projects…") }
        do {
            let token = try await validAccessToken()
            let accounts = try await listResources(url: URL(string: "https://api.frame.io/v4/accounts?page_size=100")!, accessToken: token)
            var discovered: [ProjectRef] = []
            for account in accounts {
                let accountID = Self.pathEscape(account.id)
                let workspacesURL = URL(string: "https://api.frame.io/v4/accounts/\(accountID)/workspaces?page_size=100")!
                let workspaces = try await listResources(url: workspacesURL, accessToken: token)
                for workspace in workspaces {
                    let workspaceID = Self.pathEscape(workspace.id)
                    let projectsURL = URL(string: "https://api.frame.io/v4/accounts/\(accountID)/workspaces/\(workspaceID)/projects?page_size=100")!
                    let remoteProjects = try await listResources(url: projectsURL, accessToken: token)
                    discovered += remoteProjects.map {
                        ProjectRef(
                            id: $0.id,
                            name: $0.name,
                            accountID: account.id,
                            accountName: account.name,
                            workspaceID: workspace.id,
                            workspaceName: workspace.name,
                            rootFolderID: $0.rootFolderID,
                            webURL: $0.webURL
                        )
                    }
                }
            }
            projects = discovered.sorted {
                if $0.pathLabel == $1.pathLabel { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return $0.pathLabel.localizedCaseInsensitiveCompare($1.pathLabel) == .orderedAscending
            }
            lastCatalogRefresh = .now
            state = .connected(accountName)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func link(_ remote: ProjectRef, to projectID: UUID) {
        guard let store, let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var project = store.projects[index]
        project.frameIOAccountID = remote.accountID
        project.frameIOWorkspaceID = remote.workspaceID
        project.frameIOProjectID = remote.id
        project.frameIORootFolderID = remote.rootFolderID
        project.frameIOLastSyncedAt = .now
        if let webURL = remote.webURL, !webURL.isEmpty { project.frameIOURL = webURL }
        store.updateProject(project)
    }

    func unlink(projectID: UUID) {
        guard let store, let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var project = store.projects[index]
        project.frameIOAccountID = nil
        project.frameIOWorkspaceID = nil
        project.frameIOProjectID = nil
        project.frameIORootFolderID = nil
        project.frameIOLastSyncedAt = nil
        project.frameIOURL = nil
        store.updateProject(project)
    }

    func projectReference(for projectID: UUID) -> ProjectRef? {
        guard let local = store?.projects.first(where: { $0.id == projectID }), let remoteID = local.frameIOProjectID else { return nil }
        return projects.first(where: { $0.id == remoteID && $0.workspaceID == local.frameIOWorkspaceID })
    }

    private func loadCredential() {
        guard let profileID = store?.activeProfileID,
              let raw = FramoV5Keychain.readFrameIOCredential(profileID: profileID),
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(Credential.self, from: data) else {
            credential = nil
            accountName = ""
            state = .disconnected
            return
        }
        credential = value
        accountName = value.displayName
        state = .connected(value.displayName)
    }

    private func saveCredential(_ value: Credential) {
        guard let profileID = store?.activeProfileID,
              let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return }
        FramoV5Keychain.saveFrameIOCredential(string, profileID: profileID)
    }

    private func validAccessToken() async throws -> String {
        guard var value = credential else { throw ConnectorError.notConnected }
        if value.expiresAt > .now.addingTimeInterval(30) { return value.accessToken }
        guard let refresh = value.refreshToken, !refresh.isEmpty, let clientID = effectiveClientID else {
            credential = nil
            state = .error("Frame.io session expired — connect again")
            throw ConnectorError.sessionExpired
        }
        var components = URLComponents(string: "https://ims-na1.adobelogin.com/ims/token/v3")!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(["grant_type": "refresh_token", "refresh_token": refresh])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        value.accessToken = token.access_token
        value.expiresAt = .now.addingTimeInterval(max(60, token.expires_in - 60))
        if let newRefresh = token.refresh_token, !newRefresh.isEmpty { value.refreshToken = newRefresh }
        credential = value
        saveCredential(value)
        return value.accessToken
    }

    private func exchangeCode(_ code: String, verifier: String, clientID: String) async throws -> TokenResponse {
        var components = URLComponents(string: "https://ims-na1.adobelogin.com/ims/token/v3")!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "code": code,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchCurrentUserName(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.frame.io/v4/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Frame.io" }
        let resource = (root["data"] as? [String: Any]) ?? root
        let attributes = resource["attributes"] as? [String: Any] ?? resource
        return (attributes["name"] as? String)
            ?? (attributes["email"] as? String)
            ?? "Frame.io"
    }

    private func listResources(url initialURL: URL, accessToken: String) async throws -> [Resource] {
        var output: [Resource] = []
        var nextURL: URL? = initialURL
        var pageCount = 0
        while let url = nextURL, pageCount < 50 {
            pageCount += 1
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.requireSuccess(response, data: data)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectorError.invalidResponse }
            let resources = root["data"] as? [[String: Any]] ?? []
            output += resources.compactMap(Self.resource)
            nextURL = Self.nextURL(from: root)
        }
        return output
    }

    private static func resource(_ raw: [String: Any]) -> Resource? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let attributes = raw["attributes"] as? [String: Any] ?? raw
        let name = (attributes["name"] as? String)
            ?? (attributes["display_name"] as? String)
            ?? (raw["name"] as? String)
            ?? "Untitled"
        let webURL = (attributes["web_url"] as? String)
            ?? (attributes["url"] as? String)
            ?? (raw["web_url"] as? String)
        var rootFolderID = attributes["root_folder_id"] as? String
        if rootFolderID == nil,
           let relationships = raw["relationships"] as? [String: Any],
           let folder = relationships["root_folder"] as? [String: Any],
           let data = folder["data"] as? [String: Any] {
            rootFolderID = data["id"] as? String
        }
        return Resource(id: id, name: name, webURL: webURL, rootFolderID: rootFolderID)
    }

    private static func nextURL(from root: [String: Any]) -> URL? {
        guard let links = root["links"] as? [String: Any], let next = links["next"] as? String, !next.isEmpty else { return nil }
        if let absolute = URL(string: next), absolute.scheme != nil { return absolute }
        return URL(string: "https://api.frame.io\(next.hasPrefix("/") ? "" : "/")\(next)")
    }

    private static func pathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        return Data(bytes).modoBase64URLEncodedString()
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).modoBase64URLEncodedString()
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let string = values.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.sorted().joined(separator: "&")
        return Data(string.utf8)
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Frame.io API request failed"
            throw ConnectorError.api(message)
        }
    }

    enum ConnectorError: LocalizedError {
        case invalidResponse
        case stateMismatch
        case oauthDenied(String)
        case notConnected
        case sessionExpired
        case api(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Frame.io returned an invalid response."
            case .stateMismatch: return "Frame.io sign-in could not be verified."
            case .oauthDenied(let message): return message
            case .notConnected: return "Connect Frame.io first."
            case .sessionExpired: return "Frame.io session expired. Connect again."
            case .api(let message): return message
            }
        }
    }
}

private extension Data {
    func modoBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class ModoFrameIOOAuthLoopbackReceiver: @unchecked Sendable {
    struct Callback: Sendable { var code: String?; var state: String?; var error: String? }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "be.bywarre.modo.frameio-oauth")
    private var callbackContinuation: CheckedContinuation<Callback, Error>?
    let redirectURI: String

    private init(listener: NWListener, redirectURI: String) {
        self.listener = listener
        self.redirectURI = redirectURI
    }

    static func start() async throws -> ModoFrameIOOAuthLoopbackReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = listener.port {
                        resumed = true
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "be.bywarre.modo.frameio-oauth.start"))
        }
        let receiver = ModoFrameIOOAuthLoopbackReceiver(listener: listener, redirectURI: "http://127.0.0.1:\(port.rawValue)")
        receiver.installHandler()
        return receiver
    }

    func waitForCallback() async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    private func installHandler() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, error in
                if let error { self.finish(.failure(error)); connection.cancel(); return }
                guard let data,
                      let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first,
                      let target = firstLine.split(separator: " ").dropFirst().first,
                      let url = URL(string: "http://127.0.0.1\(target)") else {
                    self.finish(.failure(ModoFrameIOConnector.ConnectorError.invalidResponse)); connection.cancel(); return
                }
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value: (String) -> String? = { name in items.first(where: { $0.name == name })?.value }
                let callback = Callback(code: value("code"), state: value("state"), error: value("error_description") ?? value("error"))
                let html = """
                <!doctype html><html><head><meta charset=\"utf-8\"><title>MODO</title></head>
                <body style=\"font-family:-apple-system;padding:48px;background:#171716;color:white\"><h2>Frame.io is connected to MODO.</h2><p>You can close this tab.</p></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(.success(callback))
            }
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard let continuation = callbackContinuation else { return }
        callbackContinuation = nil
        listener.cancel()
        switch result {
        case .success(let callback): continuation.resume(returning: callback)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
