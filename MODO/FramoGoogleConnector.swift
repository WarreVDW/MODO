import Foundation
import SwiftUI
import AppKit
import Network
import CryptoKit
import Security

@MainActor
final class FramoGoogleConnector: ObservableObject {
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
            case .connected(let email): return email.isEmpty ? "Connected" : email
            case .working(let label): return label
            case .error(let message): return message
            }
        }
    }

    private struct Credential: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String?
    }

    private struct UserInfo: Decodable { var email: String? }

    struct DriveItem: Identifiable, Hashable, Decodable {
        var id: String
        var name: String
        var mimeType: String
        var webViewLink: String?
        var modifiedTime: Date?
        var parents: [String]?

        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
        var isGoogleDoc: Bool { mimeType == "application/vnd.google-apps.document" }
        var symbol: String { isFolder ? "folder" : (isGoogleDoc ? "doc.text" : "doc") }
    }

    enum PickerMode: String, Identifiable {
        case folder = "Drive folder"
        case document = "Google Doc"
        var id: String { rawValue }
    }

    private struct DriveFile: Decodable { var id: String; var name: String?; var webViewLink: String?; var modifiedTime: Date? = nil }
    private struct DriveListResponse: Decodable { var files: [DriveItem] }
    private struct StartPageTokenResponse: Decodable { var startPageToken: String }
    private struct DriveChange: Decodable { var fileId: String?; var removed: Bool?; var file: DriveItem? }
    private struct DriveChangesResponse: Decodable {
        var nextPageToken: String?
        var newStartPageToken: String?
        var changes: [DriveChange]
    }
    private struct GoogleDocument: Decodable {
        struct Body: Decodable { var content: [StructuralElement]? }
        struct StructuralElement: Decodable { var endIndex: Int?; var paragraph: Paragraph? }
        struct Paragraph: Decodable { var elements: [ParagraphElement]? }
        struct ParagraphElement: Decodable { var textRun: TextRun? }
        struct TextRun: Decodable { var content: String? }
        var documentId: String
        var title: String?
        var body: Body?
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var accountEmail = ""
    @Published private(set) var browserItems: [DriveItem] = []
    @Published private(set) var browserPath: [DriveItem] = []
    @Published private(set) var remoteChangeProjectIDs: Set<UUID> = []
    @Published private(set) var lastIncrementalCheck: Date?

    private weak var store: FramoStudioStore?
    private var credential: Credential?

    func install(store: FramoStudioStore) {
        self.store = store
        loadCredential()
    }

    var isConnected: Bool { credential != nil }

    var effectiveClientID: String? {
        if let configured = store?.settings.googleOAuthClientID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty { return configured }
        if let bundled = (Bundle.main.object(forInfoDictionaryKey: "MODOGoogleOAuthClientID") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "FRAMOGoogleOAuthClientID") as? String) {
            let trimmed = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("$(") { return trimmed }
        }
        return nil
    }

    func connect() {
        guard state != .connecting else { return }
        guard let clientID = effectiveClientID else {
            state = .error("Add a Google OAuth desktop client ID first")
            return
        }
        state = .connecting
        Task {
            do {
                let receiver = try await FramoGoogleOAuthLoopbackReceiver.start()
                let verifier = Self.pkceVerifier()
                let challenge = Self.pkceChallenge(verifier)
                let stateToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let scopes = [
                    "openid",
                    "email",
                    "profile",
                    "https://www.googleapis.com/auth/drive.file",
                    "https://www.googleapis.com/auth/drive.metadata.readonly",
                    "https://www.googleapis.com/auth/documents"
                ].joined(separator: " ")
                var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                components.queryItems = [
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "redirect_uri", value: receiver.redirectURI),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: scopes),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "access_type", value: "offline"),
                    URLQueryItem(name: "prompt", value: "consent"),
                    URLQueryItem(name: "state", value: stateToken)
                ]
                guard let authURL = components.url else { throw ConnectorError.invalidResponse }
                NSWorkspace.shared.open(authURL)
                let callback = try await receiver.waitForCallback()
                guard callback.state == stateToken else { throw ConnectorError.stateMismatch }
                guard let code = callback.code else { throw ConnectorError.oauthDenied(callback.error ?? "Authorization was cancelled") }
                let token = try await exchangeCode(code, verifier: verifier, redirectURI: receiver.redirectURI, clientID: clientID)
                var newCredential = Credential(
                    accessToken: token.access_token,
                    refreshToken: token.refresh_token ?? "",
                    expiresAt: .now.addingTimeInterval(max(60, token.expires_in - 60)),
                    email: ""
                )
                let email = try await fetchAccountEmail(accessToken: newCredential.accessToken)
                newCredential.email = email
                credential = newCredential
                accountEmail = email
                saveCredential(newCredential)
                state = .connected(email)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        guard let profileID = store?.activeProfileID else { return }
        FramoV5Keychain.clearGoogleCredential(profileID: profileID)
        credential = nil
        accountEmail = ""
        state = .disconnected
    }

    func loadDriveItems(parentID: String? = nil) async throws -> [DriveItem] {
        let token = try await validAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let parent = parentID ?? "root"
        let query = "'\(parent)' in parents and trashed = false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "orderBy", value: "folder,name_natural"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,webViewLink,modifiedTime,parents)")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode(DriveListResponse.self, from: data).files
        browserItems = items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder && !$1.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return browserItems
    }

    func openFolder(_ folder: DriveItem) async throws {
        guard folder.isFolder else { return }
        browserPath.append(folder)
        _ = try await loadDriveItems(parentID: folder.id)
    }

    func browserBack() async throws {
        if !browserPath.isEmpty { browserPath.removeLast() }
        _ = try await loadDriveItems(parentID: browserPath.last?.id)
    }

    func resetBrowser() async throws {
        browserPath = []
        _ = try await loadDriveItems(parentID: nil)
    }

    func attach(_ item: DriveItem, mode: PickerMode, to projectID: UUID) {
        guard let store, let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var project = store.projects[index]
        switch mode {
        case .folder:
            guard item.isFolder else { return }
            project.googleDriveFolderID = item.id
            project.googleDriveFolderURL = item.webViewLink ?? "https://drive.google.com/drive/folders/\(item.id)"
            project.driveFolderURL = project.googleDriveFolderURL
        case .document:
            guard item.isGoogleDoc else { return }
            project.googleBriefDocumentID = item.id
            project.googleBriefDocumentURL = item.webViewLink ?? "https://docs.google.com/document/d/\(item.id)/edit"
            project.briefDocumentURL = project.googleBriefDocumentURL
            project.googleBriefRemoteModifiedAt = item.modifiedTime
            project.googleBriefSyncStatus = "Linked"
        }
        store.updateProject(project)
    }

    func checkIncrementalChanges() async {
        guard let store, isConnected else { return }
        do {
            state = .working("Checking Drive changes…")
            let token = try await validAccessToken()
            let key = changeTokenKey
            var pageToken = UserDefaults.standard.string(forKey: key)
            if pageToken == nil {
                pageToken = try await fetchStartPageToken(accessToken: token)
                if let pageToken { UserDefaults.standard.set(pageToken, forKey: key) }
                try await refreshLinkedDocumentMetadata(accessToken: token)
                lastIncrementalCheck = .now
                state = .connected(accountEmail)
                return
            }

            var next = pageToken
            var newestToken: String?
            var changedFileIDs = Set<String>()
            while let current = next {
                let response = try await fetchChanges(pageToken: current, accessToken: token)
                for change in response.changes {
                    if let id = change.fileId ?? change.file?.id { changedFileIDs.insert(id) }
                }
                next = response.nextPageToken
                newestToken = response.newStartPageToken ?? newestToken
                if response.nextPageToken == nil { break }
            }
            if let newestToken { UserDefaults.standard.set(newestToken, forKey: key) }

            var changedProjects = Set<UUID>()
            for index in store.projects.indices {
                guard let documentID = store.projects[index].googleBriefDocumentID,
                      changedFileIDs.contains(documentID) else { continue }
                if let metadata = try? await fetchDriveItem(id: documentID, accessToken: token) {
                    var project = store.projects[index]
                    project.googleBriefRemoteModifiedAt = metadata.modifiedTime
                    if let modified = metadata.modifiedTime,
                       let synced = project.googleBriefLastSyncedAt,
                       modified > synced.addingTimeInterval(1) {
                        project.googleBriefSyncStatus = "Update available"
                        changedProjects.insert(project.id)
                    }
                    store.updateProject(project)
                }
            }
            remoteChangeProjectIDs = changedProjects
            lastIncrementalCheck = .now
            state = .connected(accountEmail)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func syncChangedBriefs() async {
        await checkIncrementalChanges()
        for projectID in remoteChangeProjectIDs {
            do { try await pullBrief(projectID: projectID) }
            catch { store?.pluginNotice = error.localizedDescription }
        }
        remoteChangeProjectIDs.removeAll()
    }

    func createProjectWorkspace(projectID: UUID) {
        Task {
            do {
                guard let store, let index = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
                state = .working("Creating Drive workspace…")
                let project = store.projects[index]
                var folderID = project.googleDriveFolderID
                var folderURL = project.googleDriveFolderURL
                if folderID == nil {
                    let folder = try await createDriveFile(name: project.title, mimeType: "application/vnd.google-apps.folder", parentID: nil)
                    folderID = folder.id
                    folderURL = folder.webViewLink ?? "https://drive.google.com/drive/folders/\(folder.id)"
                }
                var docID = project.googleBriefDocumentID
                var docURL = project.googleBriefDocumentURL
                if docID == nil {
                    let file = try await createDriveFile(
                        name: "\(project.title) — Creative Brief",
                        mimeType: "application/vnd.google-apps.document",
                        parentID: folderID
                    )
                    docID = file.id
                    docURL = file.webViewLink ?? "https://docs.google.com/document/d/\(file.id)/edit"
                }
                var updated = store.projects[index]
                updated.googleDriveFolderID = folderID
                updated.googleDriveFolderURL = folderURL
                updated.driveFolderURL = folderURL
                updated.googleBriefDocumentID = docID
                updated.googleBriefDocumentURL = docURL
                updated.briefDocumentURL = docURL
                store.updateProject(updated)
                if !updated.brief.isEmpty { try await pushBrief(projectID: projectID) }
                state = .connected(accountEmail)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func pushBrief(projectID: UUID) async throws {
        guard let store, let project = store.projects.first(where: { $0.id == projectID }) else { return }
        guard let documentID = project.googleBriefDocumentID else { throw ConnectorError.missingDocument }
        state = .working("Sending brief to Google Docs…")
        let token = try await validAccessToken()
        let document = try await getDocument(id: documentID, accessToken: token)
        let endIndex = document.body?.content?.compactMap(\.endIndex).max() ?? 1
        var requests: [[String: Any]] = []
        let deletableEnd = max(1, endIndex - 1)
        if deletableEnd > 1 {
            requests.append(["deleteContentRange": ["range": ["startIndex": 1, "endIndex": deletableEnd]]])
        }
        if !project.brief.isEmpty {
            requests.append(["insertText": ["location": ["index": 1], "text": project.brief]])
        }
        if !requests.isEmpty {
            try await docsBatchUpdate(documentID: documentID, requests: requests, accessToken: token)
        }
        if let index = store.projects.firstIndex(where: { $0.id == projectID }) {
            var updated = store.projects[index]
            updated.googleBriefLastSyncedAt = .now
            updated.googleBriefLastSyncedHash = Self.hashText(updated.brief)
            if let metadata = try? await fetchDriveItem(id: documentID, accessToken: token) {
                updated.googleBriefRemoteModifiedAt = metadata.modifiedTime
            }
            updated.googleBriefSyncStatus = "Synced"
            remoteChangeProjectIDs.remove(projectID)
            store.updateProject(updated)
        }
        state = .connected(accountEmail)
    }

    func pullBrief(projectID: UUID) async throws {
        guard let store, let project = store.projects.first(where: { $0.id == projectID }) else { return }
        guard let documentID = project.googleBriefDocumentID else { throw ConnectorError.missingDocument }
        state = .working("Pulling brief from Google Docs…")
        let token = try await validAccessToken()
        let document = try await getDocument(id: documentID, accessToken: token)
        let text = document.body?.content?.flatMap { $0.paragraph?.elements ?? [] }
            .compactMap { $0.textRun?.content }.joined() ?? ""
        if let index = store.projects.firstIndex(where: { $0.id == projectID }) {
            var updated = store.projects[index]
            updated.brief = text.trimmingCharacters(in: .newlines)
            // Google Docs currently syncs MODO's plain-text document body. Clearing
            // stale RTF prevents the rich-text cache from re-inserting older content.
            updated.briefRTF = nil
            updated.googleBriefLastSyncedAt = .now
            updated.googleBriefLastSyncedHash = Self.hashText(updated.brief)
            if let metadata = try? await fetchDriveItem(id: documentID, accessToken: token) {
                updated.googleBriefRemoteModifiedAt = metadata.modifiedTime
            }
            updated.googleBriefSyncStatus = "Synced"
            remoteChangeProjectIDs.remove(projectID)
            store.updateProject(updated)
            store.projectRefreshToken = UUID()
        }
        state = .connected(accountEmail)
    }

    func openBrief(projectID: UUID) {
        guard let project = store?.projects.first(where: { $0.id == projectID }),
              let raw = project.googleBriefDocumentURL ?? project.briefDocumentURL,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadCredential() {
        guard let profileID = store?.activeProfileID,
              let raw = FramoV5Keychain.readGoogleCredential(profileID: profileID),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Credential.self, from: data) else {
            credential = nil
            accountEmail = ""
            state = .disconnected
            return
        }
        credential = decoded
        accountEmail = decoded.email
        state = .connected(decoded.email)
    }

    func reloadForActiveProfile() { loadCredential() }

    private func saveCredential(_ credential: Credential) {
        guard let profileID = store?.activeProfileID,
              let data = try? JSONEncoder().encode(credential),
              let string = String(data: data, encoding: .utf8) else { return }
        FramoV5Keychain.saveGoogleCredential(string, profileID: profileID)
    }

    private func validAccessToken() async throws -> String {
        guard var credential else { throw ConnectorError.notConnected }
        if credential.expiresAt > .now.addingTimeInterval(15) { return credential.accessToken }
        guard !credential.refreshToken.isEmpty, let clientID = effectiveClientID else { throw ConnectorError.notConnected }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "refresh_token": credential.refreshToken,
            "grant_type": "refresh_token"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        let refreshed = try JSONDecoder().decode(TokenResponse.self, from: data)
        credential.accessToken = refreshed.access_token
        credential.expiresAt = .now.addingTimeInterval(max(60, refreshed.expires_in - 60))
        if let refresh = refreshed.refresh_token, !refresh.isEmpty { credential.refreshToken = refresh }
        self.credential = credential
        saveCredential(credential)
        return credential.accessToken
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String, clientID: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchAccountEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(UserInfo.self, from: data).email ?? "Google account"
    }

    private var changeTokenKey: String {
        "modo.google.drive.change-token.\(store?.activeProfileID?.uuidString ?? "global")"
    }

    private func fetchStartPageToken(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/changes/startPageToken")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(StartPageTokenResponse.self, from: data).startPageToken
    }

    private func fetchChanges(pageToken: String, accessToken: String) async throws -> DriveChangesResponse {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")!
        components.queryItems = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "includeRemoved", value: "true"),
            URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,webViewLink,modifiedTime,parents))")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DriveChangesResponse.self, from: data)
    }

    private func fetchDriveItem(id: String, accessToken: String) async throws -> DriveItem {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(escaped)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "id,name,mimeType,webViewLink,modifiedTime,parents")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DriveItem.self, from: data)
    }

    private func refreshLinkedDocumentMetadata(accessToken: String) async throws {
        guard let store else { return }
        for index in store.projects.indices {
            guard let documentID = store.projects[index].googleBriefDocumentID else { continue }
            if let metadata = try? await fetchDriveItem(id: documentID, accessToken: accessToken) {
                var project = store.projects[index]
                project.googleBriefRemoteModifiedAt = metadata.modifiedTime
                if let modified = metadata.modifiedTime,
                   let synced = project.googleBriefLastSyncedAt,
                   modified > synced.addingTimeInterval(1) {
                    project.googleBriefSyncStatus = "Update available"
                    remoteChangeProjectIDs.insert(project.id)
                }
                store.updateProject(project)
            }
        }
    }

    private static func hashText(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func createDriveFile(name: String, mimeType: String, parentID: String?) async throws -> DriveFile {
        let token = try await validAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [URLQueryItem(name: "fields", value: "id,name,webViewLink")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "mimeType": mimeType]
        if let parentID { body["parents"] = [parentID] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    private func getDocument(id: String, accessToken: String) async throws -> GoogleDocument {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var request = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(escaped)")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(GoogleDocument.self, from: data)
    }

    private func docsBatchUpdate(documentID: String, requests: [[String: Any]], accessToken: String) async throws {
        let escaped = documentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? documentID
        var request = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(escaped):batchUpdate")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireSuccess(response, data: data)
    }

    private static func pkceVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
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
            let message = String(data: data, encoding: .utf8) ?? "Google API request failed"
            throw ConnectorError.api(message)
        }
    }

    enum ConnectorError: LocalizedError {
        case invalidResponse, stateMismatch, oauthDenied(String), notConnected, missingDocument, api(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Google returned an invalid response."
            case .stateMismatch: return "Google sign-in could not be verified."
            case .oauthDenied(let message): return message
            case .notConnected: return "Connect Google Drive + Docs first."
            case .missingDocument: return "Create a Google Docs brief for this project first."
            case .api(let message): return message
            }
        }
    }
}

struct ModoGoogleDrivePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var connector: FramoGoogleConnector
    let projectID: UUID
    let mode: FramoGoogleConnector.PickerMode
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var visibleItems: [FramoGoogleConnector.DriveItem] {
        connector.browserItems.filter { item in
            if item.isFolder { return true }
            return mode == .document && item.isGoogleDoc
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await goBack() }
                } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle())
                .disabled(connector.browserPath.isEmpty || isLoading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose \(mode.rawValue)").font(.system(size: 15, weight: .semibold))
                    Text(pathLabel).font(.system(size: 9)).foregroundStyle(StudioTheme.tertiary).lineLimit(1)
                }
                Spacer()
                Button("Refresh") { Task { await reload() } }.buttonStyle(SecondaryButtonStyle())
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(16)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioTheme.red)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if mode == .folder, let current = connector.browserPath.last {
                        Button {
                            connector.attach(current, mode: .folder, to: projectID)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(StudioTheme.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Use this folder").font(.system(size: 11, weight: .semibold))
                                    Text(current.name).font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).frame(height: 48)
                            .background(StudioTheme.soft.opacity(0.78))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain).studioPointerCursor()
                    }

                    ForEach(visibleItems) { item in
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(StudioTheme.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(item.isFolder ? "Folder" : "Google Docs")
                                    .font(.system(size: 8)).foregroundStyle(StudioTheme.tertiary)
                            }
                            Spacer()
                            if item.isFolder {
                                if mode == .folder {
                                    Button("Choose") {
                                        connector.attach(item, mode: .folder, to: projectID)
                                        dismiss()
                                    }
                                    .buttonStyle(SecondaryButtonStyle())
                                }
                                Button("Open") { Task { await open(item) } }
                                    .buttonStyle(SecondaryButtonStyle())
                            } else if mode == .document {
                                Button("Link") {
                                    connector.attach(item, mode: .document, to: projectID)
                                    dismiss()
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 54)
                        .background(StudioTheme.elevated.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if visibleItems.isEmpty && !isLoading {
                        VStack(spacing: 6) {
                            Text("Nothing here").font(.system(size: 12, weight: .semibold))
                            Text(mode == .folder ? "This Drive folder has no subfolders." : "This folder has no Google Docs MODO can access.")
                                .font(.system(size: 9)).foregroundStyle(StudioTheme.secondary)
                        }
                        .padding(.vertical, 44)
                    }
                }
                .padding(12)
            }
            .overlay {
                if isLoading { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: 620, height: 520)
        .background(StudioTheme.canvas)
        .task { await reset() }
    }

    private var pathLabel: String {
        connector.browserPath.isEmpty ? "My Drive" : "My Drive / " + connector.browserPath.map(\.name).joined(separator: " / ")
    }

    private func reset() async {
        isLoading = true; defer { isLoading = false }
        do { try await connector.resetBrowser(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func reload() async {
        isLoading = true; defer { isLoading = false }
        do { _ = try await connector.loadDriveItems(parentID: connector.browserPath.last?.id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func open(_ item: FramoGoogleConnector.DriveItem) async {
        isLoading = true; defer { isLoading = false }
        do { try await connector.openFolder(item); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func goBack() async {
        isLoading = true; defer { isLoading = false }
        do { try await connector.browserBack(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class FramoGoogleOAuthLoopbackReceiver: @unchecked Sendable {
    struct Callback: Sendable { var code: String?; var state: String?; var error: String? }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "be.bywarre.framo.google-oauth")
    private var callbackContinuation: CheckedContinuation<Callback, Error>?
    let redirectURI: String

    private init(listener: NWListener, redirectURI: String) {
        self.listener = listener
        self.redirectURI = redirectURI
    }

    static func start() async throws -> FramoGoogleOAuthLoopbackReceiver {
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
            listener.start(queue: DispatchQueue(label: "be.bywarre.framo.google-oauth.start"))
        }
        let receiver = FramoGoogleOAuthLoopbackReceiver(listener: listener, redirectURI: "http://127.0.0.1:\(port.rawValue)")
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
                if let error {
                    self.finish(.failure(error)); connection.cancel(); return
                }
                guard let data, let request = String(data: data, encoding: .utf8),
                      let firstLine = request.components(separatedBy: "\r\n").first,
                      let target = firstLine.split(separator: " ").dropFirst().first,
                      let url = URL(string: "http://127.0.0.1\(target)") else {
                    self.finish(.failure(FramoGoogleConnector.ConnectorError.invalidResponse)); connection.cancel(); return
                }
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let value: (String) -> String? = { name in items.first(where: { $0.name == name })?.value }
                let callback = Callback(code: value("code"), state: value("state"), error: value("error_description") ?? value("error"))
                let html = """
                <!doctype html><html><head><meta charset=\"utf-8\"><title>MODO</title></head>
                <body style=\"font-family:-apple-system;padding:48px;background:#171716;color:white\"><h2>MODO is connected.</h2><p>You can close this tab and return to MODO.</p></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(.success(callback))
            }
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard let callbackContinuation else { return }
        self.callbackContinuation = nil
        listener.cancel()
        switch result {
        case .success(let callback): callbackContinuation.resume(returning: callback)
        case .failure(let error): callbackContinuation.resume(throwing: error)
        }
    }
}
