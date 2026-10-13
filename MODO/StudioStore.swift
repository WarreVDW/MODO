import Foundation
import SwiftUI
@preconcurrency import MultipeerConnectivity
import AppKit
import Network
import UniformTypeIdentifiers
import Security
import EventKit
import CryptoKit


@MainActor
final class FramoStudioStore: ObservableObject {
    @Published var projects: [StudioProject] = [] { didSet { scheduleSave(); refreshHostShareIndex() } }
    @Published var tasks: [StudioTask] = [] { didSet { scheduleSave() } }
    @Published var events: [StudioEvent] = [] { didSet { scheduleSave() } }
    @Published var spaces: [StudioSpace] = [] { didSet { scheduleSave() } }
    @Published var places: [StudioPlace] = [] { didSet { scheduleSave() } }
    @Published var invoices: [ModoInvoice] = [] { didSet { scheduleSave() } }
    @Published var business = ModoBusinessState() { didSet { scheduleSave() } }
    @Published var settings = StudioSettings() { didSet { StudioTheme.sync(settings: settings); if !isUpdatingBackupMetadata { scheduleSave() } } }
    @Published var selection: SidebarDestination = .home
    @Published var selectedProjectID: UUID?
    @Published var selectedSpaceID: UUID?
    @Published var showProjectCreator = false
    @Published var searchText = ""
    @Published var activeTimerProjectID: UUID?
    @Published var activeTimerStartedAt: Date?
    @Published private(set) var focusSessionSeconds: TimeInterval = 0
    @Published var duoProjectID: UUID?
    @Published var projectSectionSelection: [UUID: ProjectSection] = [:]
    @Published var lastFileLinkMessage: String?
    @Published var pluginNotice: String? {
        didSet {
            guard !isLoading, let message = pluginNotice, !message.isEmpty else { return }
            recordNotificationMessage(message)
        }
    }
    @Published var showNotificationCenter = false
    @Published var notificationState = FramoNotificationState() {
        didSet { saveNotificationState() }
    }
    @Published var requestedSettingsPane: String?
    @Published var backupStatus: String = "Not configured"
    @Published var showGlobalSearch = false
    @Published var showTimeLauncher = false
    @Published var projectRefreshToken = UUID()
    @Published var calendarIntegrationStatus = "Not connected"
    @Published var inspectedCalendarItem: StudioEvent?
    @Published var updateStatus: FramoUpdateStatus = .idle
    @Published var availableUpdate: FramoRemoteRelease?
    /// Non-nil only when MODO had to recover from or isolate a damaged workspace.
    @Published var workspaceRecoveryNotice: String?
    @Published private(set) var profiles: [FramoWorkspaceProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var profileGatePresented = true
    @Published private(set) var isProfileLocked = false
    @Published var profileAccessError: String?

    let localTransfer = FramoV5LocalTransferService()
    let hostSharing = FramoV5HostService()
    let remoteAccess = FramoV5RemoteAccessService()
    let torConnect = FramoTorConnectService()
    let pluginManager = FramoV5PluginManager()
    let syncthing = FramoV5SyncthingService()
    let calendarBridge = FramoCalendarBridge()
    let googleConnector = FramoGoogleConnector()
    let frameIOConnector = ModoFrameIOConnector()
    let peppolConnector = ModoPeppolConnector()
    let cloudSync = FramoCloudSyncService()
    let mcpServer = FramoMCPServer()

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.37.0"
    }

    static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "370"
    }

    var versionLabel: String { "Version \(Self.appVersion) (\(Self.buildNumber))" }

    var hasConfiguredUpdateFeed: Bool { updateFeedURL != nil }

    func isFeatureAvailable(_ feature: FramoFeature) -> Bool {
        FramoSemanticVersion(Self.appVersion) >= FramoSemanticVersion(feature.minimumVersion)
    }

    func requiredVersion(for feature: FramoFeature) -> String { feature.minimumVersion }



    private var updateFeedURL: URL? {
        let key = settings.effectiveUpdateChannel == .beta ? "MODOBetaUpdateFeedURL" : "MODOUpdateFeedURL"
        let legacyKey = settings.effectiveUpdateChannel == .beta ? "FRAMOBetaUpdateFeedURL" : "FRAMOUpdateFeedURL"
        guard let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: legacyKey) as? String),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return url
    }

    private var fallbackDownloadURL: URL? {
        guard let raw = (Bundle.main.object(forInfoDictionaryKey: "MODODownloadURL") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "FRAMODownloadURL") as? String) else { return nil }
        return URL(string: raw)
    }

    private func scheduleAutomaticUpdateCheckIfNeeded() {
        guard settings.effectiveAutomaticUpdateChecks, updateFeedURL != nil else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 12 * 60 * 60 { return }
        Task { [weak self] in await self?.checkForUpdates(silent: true) }
    }

    func checkForUpdates(silent: Bool = false) async {
        updateStatus = .checking
        settings.lastUpdateCheck = Date()

        guard let feedURL = updateFeedURL else {
            let bundled = FramoReleaseCatalog.latestBundled
            if FramoSemanticVersion(Self.appVersion) < FramoSemanticVersion(bundled.version) {
                let release = FramoRemoteRelease(
                    version: bundled.version,
                    build: bundled.build,
                    title: bundled.title,
                    notes: bundled.highlights,
                    downloadURL: nil,
                    publishedAt: bundled.date
                )
                availableUpdate = release
                updateStatus = .updateAvailable(release.version)
            } else {
                availableUpdate = nil
                updateStatus = .current
            }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: feedURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(FramoRemoteRelease.self, from: data)
            if FramoSemanticVersion(release.version) > FramoSemanticVersion(Self.appVersion) {
                availableUpdate = release
                updateStatus = .updateAvailable(release.version)
            } else {
                availableUpdate = nil
                updateStatus = .current
            }
        } catch {
            if silent {
                updateStatus = .idle
            } else {
                updateStatus = .failed("Couldn’t check for updates")
            }
        }
    }

    func openAvailableUpdate() {
        let raw = availableUpdate?.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = raw.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if let url = remoteURL ?? fallbackDownloadURL {
            NSWorkspace.shared.open(url)
        } else {
            pluginNotice = "No update download URL is configured for this build"
        }
    }

    private enum NavigationTarget: Equatable {
        case destination(SidebarDestination)
        case project(UUID)
        case space(UUID)
    }

    private var backStack: [NavigationTarget] = []
    private var forwardStack: [NavigationTarget] = []
    private var isLoading = true
    private var profileRootOverride: URL?
    private var activeProfileSecurityScopedURL: URL?
    private var saveTask: Task<Void, Never>?
    private var automaticBackupTask: Task<Void, Never>?
    private var periodicBackupTask: Task<Void, Never>?
    private var isWritingBackup = false
    private var isUpdatingBackupMetadata = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Compact JSON materially reduces encoding and disk I/O.
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var databaseURL: URL {
        workspaceSupportRoot().appendingPathComponent("studio.json")
    }

    private var previousDatabaseURL: URL {
        workspaceSupportRoot().appendingPathComponent("studio.previous.json")
    }

    private var recoveryRootURL: URL {
        let url = workspaceSupportRoot().appendingPathComponent("Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func globalSupportRoot() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bywarre Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workspaceSupportRoot() -> URL {
        let root = profileRootOverride ?? Self.globalSupportRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Stable root for profile-scoped companion services (CloudKit sync ledger,
    /// connector metadata and portable workspace helpers).
    var workspaceRootURL: URL { workspaceSupportRoot() }

    private struct ProfileRegistry: Codable {
        var profiles: [FramoWorkspaceProfile]
        var activeProfileID: UUID?
    }

    private var profileRegistryURL: URL {
        Self.globalSupportRoot().appendingPathComponent("profiles.json")
    }

    private var previousProfileRegistryURL: URL {
        Self.globalSupportRoot().appendingPathComponent("profiles.previous.json")
    }

    var activeProfile: FramoWorkspaceProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first(where: { $0.id == activeProfileID })
    }

    var activeProfileName: String { activeProfile?.name ?? "Workspace" }

    init() {
        loadProfileRegistry()
        if !activateProfileRoot(for: activeProfileID), let local = profiles.first(where: { $0.storageKind == .local }) {
            activeProfileID = local.id
            _ = activateProfileRoot(for: local.id)
            saveProfileRegistry()
        }
        load()
        migrateLegacySecretsToKeychain()
        loadNotificationState()
        StudioTheme.sync(settings: settings)
        configureFramoV5SyncthingService()
        googleConnector.install(store: self)
        frameIOConnector.install(store: self)
        peppolConnector.install(store: self)
        cloudSync.install(store: self)
        mcpServer.install(store: self)
        isLoading = false
        refreshNotifications()
        refreshBackupStatus()
        startPeriodicBackupLoop()
        isProfileLocked = activeProfile?.isPasswordProtected ?? false
        profileGatePresented = true
        // Networking and background sharing deliberately stay stopped until the
        // user opens/unlocks the selected workspace. A locked profile must not
        // keep serving its database or linked files in the background.
        suspendProfileServices()
    }

    private func loadProfileRegistry() {
        for candidate in [profileRegistryURL, previousProfileRegistryURL] {
            if let data = try? Data(contentsOf: candidate),
               let registry = try? decoder.decode(ProfileRegistry.self, from: data),
               !registry.profiles.isEmpty {
                profiles = registry.profiles
                activeProfileID = registry.activeProfileID.flatMap { id in registry.profiles.contains(where: { $0.id == id }) ? id : nil } ?? registry.profiles.first?.id
                return
            }
        }

        // Keep the existing MODO workspace exactly where older releases stored it.
        // New profiles receive their own directory under Profiles/.
        let defaultProfile = FramoWorkspaceProfile(name: "Default workspace", storageKind: .local, localFolderName: nil)
        profiles = [defaultProfile]
        activeProfileID = defaultProfile.id
        saveProfileRegistry()
    }

    private func saveProfileRegistry() {
        let registry = ProfileRegistry(profiles: profiles, activeProfileID: activeProfileID)
        guard let data = try? encoder.encode(registry) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: profileRegistryURL.path) {
            try? fm.removeItem(at: previousProfileRegistryURL)
            try? fm.copyItem(at: profileRegistryURL, to: previousProfileRegistryURL)
        }
        try? data.write(to: profileRegistryURL, options: .atomic)
        if let id = activeProfileID { UserDefaults.standard.set(id.uuidString, forKey: "framo.activeProfileID") }
    }

    private func localRoot(for profile: FramoWorkspaceProfile) -> URL {
        if let folder = profile.localFolderName, !folder.isEmpty {
            return Self.globalSupportRoot()
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
        }
        return Self.globalSupportRoot()
    }

    private func resolvedPortableRoot(for profile: FramoWorkspaceProfile) -> URL? {
        if let bookmark = profile.externalBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        if let path = profile.externalPath, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return nil
    }

    @discardableResult
    private func activateProfileRoot(for profileID: UUID?) -> Bool {
        if let activeProfileSecurityScopedURL {
            activeProfileSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.activeProfileSecurityScopedURL = nil
        }
        profileAccessError = nil
        guard let profileID, let profile = profiles.first(where: { $0.id == profileID }) else {
            profileRootOverride = Self.globalSupportRoot()
            return true
        }
        switch profile.storageKind {
        case .local:
            profileRootOverride = localRoot(for: profile)
        case .portable:
            guard let url = resolvedPortableRoot(for: profile),
                  FileManager.default.fileExists(atPath: url.path) else {
                profileAccessError = "That portable workspace is unavailable. Connect its drive, then choose Open portable to reconnect it."
                return false
            }
            if url.startAccessingSecurityScopedResource() { activeProfileSecurityScopedURL = url }
            profileRootOverride = url
        }
        if let root = profileRootOverride {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            catch {
                profileAccessError = "MODO can’t access this workspace folder: \(error.localizedDescription)"
                return false
            }
        }
        return true
    }

    private func writeEmptyWorkspace(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = StudioDatabase(projects: [], tasks: [], events: [], settings: StudioSettings(), spaces: [], places: [], invoices: [], business: ModoBusinessState())
        let data = try encoder.encode(database)
        try data.write(to: root.appendingPathComponent("studio.json"), options: .atomic)
    }

    private func portableProfileMetadataURL(_ root: URL) -> URL {
        root.appendingPathComponent(".framo-profile.json")
    }

    private func writePortableMetadata(_ profile: FramoWorkspaceProfile, root: URL) {
        var portable = profile
        portable.externalBookmark = nil
        portable.externalPath = nil
        guard let data = try? encoder.encode(portable) else { return }
        try? data.write(to: portableProfileMetadataURL(root), options: .atomic)
    }

    @discardableResult
    func createLocalProfile(name: String, password: String = "") -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var profile = FramoWorkspaceProfile(name: clean, storageKind: .local, localFolderName: UUID().uuidString)
        applyPassword(password, to: &profile)
        let root = localRoot(for: profile)
        do { try writeEmptyWorkspace(at: root) }
        catch { pluginNotice = "Couldn't create profile: \(error.localizedDescription)"; return nil }
        profiles.append(profile)
        saveProfileRegistry()
        switchProfile(to: profile.id)
        return profile.id
    }

    @discardableResult
    func createPortableProfile(name: String, password: String = "", at root: URL) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let existingDatabase = root.appendingPathComponent("studio.json")
            let existingMetadata = portableProfileMetadataURL(root)
            if FileManager.default.fileExists(atPath: existingDatabase.path) || FileManager.default.fileExists(atPath: existingMetadata.path) {
                pluginNotice = "That folder already contains a MODO workspace. Use Open portable instead of creating over it."
                return nil
            }
            let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var profile = FramoWorkspaceProfile(name: clean, storageKind: .portable, externalPath: root.path, externalBookmark: bookmark)
            applyPassword(password, to: &profile)
            try writeEmptyWorkspace(at: root)
            writePortableMetadata(profile, root: root)
            profiles.removeAll { $0.id == profile.id }
            profiles.append(profile)
            saveProfileRegistry()
            switchProfile(to: profile.id)
            return profile.id
        } catch {
            pluginNotice = "Couldn't create portable profile: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func registerPortableProfile(at root: URL) -> UUID? {
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var profile: FramoWorkspaceProfile
            let metadataURL = portableProfileMetadataURL(root)
            if let data = try? Data(contentsOf: metadataURL), let decoded = try? decoder.decode(FramoWorkspaceProfile.self, from: data) {
                profile = decoded
            } else {
                profile = FramoWorkspaceProfile(name: root.lastPathComponent.isEmpty ? "Portable workspace" : root.lastPathComponent, storageKind: .portable)
            }
            profile.storageKind = .portable
            profile.externalPath = root.path
            profile.externalBookmark = bookmark
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("studio.json").path) {
                try writeEmptyWorkspace(at: root)
            }
            writePortableMetadata(profile, root: root)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            else { profiles.append(profile) }
            saveProfileRegistry()
            switchProfile(to: profile.id)
            return profile.id
        } catch {
            pluginNotice = "Couldn't open portable profile: \(error.localizedDescription)"
            return nil
        }
    }

    func switchProfile(to id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        suspendProfileServices()
        if activeProfileID == id {
            isProfileLocked = activeProfile?.isPasswordProtected ?? false
            profileGatePresented = true
            return
        }

        saveTask?.cancel()
        if activeTimerProjectID != nil { stopTimer() }
        saveNow()
        let previousID = activeProfileID
        guard activateProfileRoot(for: id) else {
            let accessError = profileAccessError
            if let previousID { _ = activateProfileRoot(for: previousID) }
            profileAccessError = accessError
            profileGatePresented = true
            return
        }
        isLoading = true
        activeProfileID = id
        saveProfileRegistry()

        projects = []
        tasks = []
        events = []
        spaces = []
        places = []
        invoices = []
        business = ModoBusinessState()
        settings = StudioSettings()
        notificationState = FramoNotificationState()
        selection = .home
        selectedProjectID = nil
        selectedSpaceID = nil
        duoProjectID = nil
        backStack.removeAll()
        forwardStack.removeAll()
        workspaceRecoveryNotice = nil
        load()
        loadNotificationState()
        migrateLegacySecretsToKeychain()
        StudioTheme.sync(settings: settings)
        configureFramoV5SyncthingService()
        googleConnector.reloadForActiveProfile()
        frameIOConnector.reloadForActiveProfile()
        peppolConnector.reloadForActiveProfile()
        cloudSync.refreshForActiveProfile()
        mcpServer.stop()
        isLoading = false
        refreshNotifications()
        refreshBackupStatus()
        isProfileLocked = activeProfile?.isPasswordProtected ?? false
        profileGatePresented = true
    }

    var experimentalRemoteConnectEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "MODOEnableExperimentalRemoteConnect") as? Bool) == true
    }

    private func suspendProfileServices() {
        localTransfer.stop()
        hostSharing.stop()
        remoteAccess.disconnect()
        torConnect.stop()
        stopManagedSyncthing()
        mcpServer.stop()
        FramoNotchTimerController.shared.refreshPreferences()
    }

    private func resumeProfileServicesIfNeeded() {
        guard !profileGatePresented else { return }
        if settings.effectiveLocalTransferEnabled { localTransfer.start() }
        if settings.effectiveHostSharingEnabled { startHostSharing() }
        if experimentalRemoteConnectEnabled,
           settings.effectiveFramoConnectRemoteEnabled,
           settings.effectiveFramoConnectAutoStart {
            startFramoConnectRemote()
        }
        if isPluginEnabled("org.framo.syncthing"), settings.effectiveSyncthingMode == .managed, settings.effectiveSyncthingAutoStart {
            startManagedSyncthing()
        }
        if settings.effectiveMCPEnabled { mcpServer.start() }
        FramoNotchTimerController.shared.refreshPreferences()
        if settings.effectiveCloudSyncEnabled && settings.effectiveCloudAutoSyncEnabled { cloudSync.scheduleSync(delay: 0.5) }
    }

    func openActiveProfile() {
        guard activeProfile?.isPasswordProtected != true else { return }
        isProfileLocked = false
        profileGatePresented = false
        resumeProfileServicesIfNeeded()
    }

    func unlockActiveProfile(password: String) -> Bool {
        guard let profile = activeProfile else { return false }
        guard profile.isPasswordProtected else {
            isProfileLocked = false
            profileGatePresented = false
            resumeProfileServicesIfNeeded()
            return true
        }
        guard verifyPassword(password, profile: profile) else { return false }
        upgradeLegacyPasswordIfNeeded(password, profileID: profile.id)
        isProfileLocked = false
        profileGatePresented = false
        resumeProfileServicesIfNeeded()
        return true
    }

    /// Called only after macOS LocalAuthentication has successfully verified the current user.
    /// This unlocks the MODO application layer; it does not decrypt workspace files.
    func unlockActiveProfileUsingDeviceAuthentication() {
        guard activeProfile != nil else { return }
        isProfileLocked = false
        profileGatePresented = false
        profileAccessError = nil
        resumeProfileServicesIfNeeded()
    }

    func lockActiveProfile() {
        suspendProfileServices()
        showGlobalSearch = false
        showNotificationCenter = false
        showTimeLauncher = false
        isProfileLocked = activeProfile?.isPasswordProtected ?? false
        profileGatePresented = true
    }

    @discardableResult
    func setActiveProfilePassword(_ password: String) -> Bool {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return false }

        let clean = password.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = profiles[index]

        if clean.isEmpty {
            applyPassword("", to: &profile)
            profile.recoveryCodeDigests = nil
            FramoV5Keychain.clearRecoveryAuthenticatorSecret(profileID: id)
            profiles[index] = profile
            persistProfileSecurity(profile)
            isProfileLocked = false
            return true
        }

        guard clean.count >= 6 else { return false }
        applyPassword(clean, to: &profile)
        profiles[index] = profile
        persistProfileSecurity(profile)
        isProfileLocked = false
        return profile.isPasswordProtected
    }

    var activeProfileHasRecoveryCodes: Bool {
        activeProfile?.hasRecoveryCodes == true
    }

    var activeProfileHasAuthenticator: Bool {
        guard let id = activeProfileID else { return false }
        let secret = FramoV5Keychain.readRecoveryAuthenticatorSecret(profileID: id) ?? ""
        return !secret.isEmpty
    }

    @discardableResult
    func regenerateActiveProfileRecoveryKit() -> ModoRecoveryKit? {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].isPasswordProtected else { return nil }

        let codes = (0..<8).map { _ in makeRecoveryCode() }
        let secret = makeAuthenticatorSecret()

        var profile = profiles[index]
        profile.recoveryCodeDigests = codes.map { recoveryCodeDigest($0, profileID: id) }
        profiles[index] = profile
        FramoV5Keychain.saveRecoveryAuthenticatorSecret(secret, profileID: id)
        persistProfileSecurity(profile)

        return ModoRecoveryKit(
            workspaceName: profile.name,
            backupCodes: codes,
            authenticatorSecret: secret
        )
    }

    func disableActiveProfileRecovery() {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }

        var profile = profiles[index]
        profile.recoveryCodeDigests = nil
        profiles[index] = profile
        FramoV5Keychain.clearRecoveryAuthenticatorSecret(profileID: id)
        persistProfileSecurity(profile)
    }

    func unlockActiveProfile(recoveryCode: String) -> Bool {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return false }

        let digest = recoveryCodeDigest(recoveryCode, profileID: id)
        guard var digests = profiles[index].recoveryCodeDigests,
              let matchIndex = digests.firstIndex(of: digest) else { return false }

        // Backup codes are single-use.
        digests.remove(at: matchIndex)
        var profile = profiles[index]
        profile.recoveryCodeDigests = digests
        profiles[index] = profile
        persistProfileSecurity(profile)
        finishProfileUnlock()
        return true
    }

    func unlockActiveProfile(authenticatorCode: String) -> Bool {
        guard let id = activeProfileID,
              let secret = FramoV5Keychain.readRecoveryAuthenticatorSecret(profileID: id),
              !secret.isEmpty else { return false }

        let clean = authenticatorCode.filter(\.isNumber)
        guard clean.count == 6 else { return false }

        // Allow one 30-second step of clock drift in either direction.
        let now = Date()
        for step in -1...1 {
            let date = now.addingTimeInterval(TimeInterval(step * 30))
            if totpCode(secretBase32: secret, date: date) == clean {
                finishProfileUnlock()
                return true
            }
        }
        return false
    }

    private func finishProfileUnlock() {
        isProfileLocked = false
        profileGatePresented = false
        profileAccessError = nil
        resumeProfileServicesIfNeeded()
    }

    private func persistProfileSecurity(_ profile: FramoWorkspaceProfile) {
        saveProfileRegistry()
        if profile.storageKind == .portable,
           let root = resolvedPortableRoot(for: profile) {
            writePortableMetadata(profile, root: root)
        }
    }

    private func makeRecoveryCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        if status != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8.prefix(8))
        }

        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        let raw = String(characters)
        let midpoint = raw.index(raw.startIndex, offsetBy: 4)
        return String(raw[..<midpoint]) + "-" + String(raw[midpoint...])
    }

    private func recoveryCodeDigest(_ code: String, profileID: UUID) -> String {
        let canonical = code
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        let payload = Data((profileID.uuidString + "|" + canonical).utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private func makeAuthenticatorSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        if status != errSecSuccess {
            bytes = Array(UUID().uuidString.replacingOccurrences(of: "-", with: "").utf8.prefix(20))
        }
        return base32Encode(Data(bytes))
    }

    private func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var buffer: UInt64 = 0
        var bits = 0

        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((buffer >> UInt64(bits)) & 0x1F)
                output.append(alphabet[index])
            }
        }

        if bits > 0 {
            let index = Int((buffer << UInt64(5 - bits)) & 0x1F)
            output.append(alphabet[index])
        }

        return output
    }

    private func base32Decode(_ value: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let map = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
        var buffer: UInt64 = 0
        var bits = 0
        var bytes: [UInt8] = []

        for character in value.uppercased() where character != "=" && !character.isWhitespace {
            guard let mapped = map[character] else { return nil }
            buffer = (buffer << 5) | UInt64(mapped)
            bits += 5

            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }

        return Data(bytes)
    }

    private func totpCode(secretBase32: String, date: Date) -> String? {
        guard let keyData = base32Decode(secretBase32), !keyData.isEmpty else { return nil }

        let interval = UInt64(max(0, floor(date.timeIntervalSince1970 / 30.0)))
        var counter = interval.bigEndian
        let counterData = withUnsafeBytes(of: &counter) { Data($0) }

        let key = SymmetricKey(data: keyData)
        let authentication = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let bytes = Array(authentication)
        guard bytes.count >= 20 else { return nil }

        let offset = Int(bytes[bytes.count - 1] & 0x0F)
        guard offset + 3 < bytes.count else { return nil }

        let binary =
            (UInt32(bytes[offset] & 0x7F) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])

        return String(format: "%06u", binary % 1_000_000)
    }

    func setActiveProfileAutoLock(minutes: Int) {
        guard let id = activeProfileID, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].autoLockMinutes = max(0, min(minutes, 240))
        let profile = profiles[index]
        saveProfileRegistry()
        if profile.storageKind == .portable, let root = resolvedPortableRoot(for: profile) { writePortableMetadata(profile, root: root) }
    }

    func renameActiveProfile(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let id = activeProfileID, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = clean
        let profile = profiles[index]
        saveProfileRegistry()
        if profile.storageKind == .portable, let root = resolvedPortableRoot(for: profile) { writePortableMetadata(profile, root: root) }
    }

    func revealActiveProfileFolder() {
        NSWorkspace.shared.open(workspaceSupportRoot())
    }

    private func applyPassword(_ password: String, to profile: inout FramoWorkspaceProfile) {
        let clean = password
        guard !clean.isEmpty else {
            profile.passwordSaltHex = nil
            profile.passwordDigestHex = nil
            profile.passwordKDF = nil
            profile.passwordIterations = nil
            return
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        if status != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8.prefix(16))
        }

        let salt = Data(bytes)
        let iterations = 120_000
        profile.passwordSaltHex = salt.hexString
        profile.passwordKDF = "PBKDF2-HMAC-SHA256"
        profile.passwordIterations = iterations
        profile.passwordDigestHex = pbkdf2SHA256(
            password: clean,
            salt: salt,
            iterations: iterations,
            keyLength: 32
        ).hexString
    }

    private func verifyPassword(_ password: String, profile: FramoWorkspaceProfile) -> Bool {
        guard let saltHex = profile.passwordSaltHex,
              let expected = profile.passwordDigestHex else { return true }

        if profile.passwordKDF == "PBKDF2-HMAC-SHA256",
           let salt = Data(hexString: saltHex) {
            let iterations = max(60_000, profile.passwordIterations ?? 120_000)
            return secureDigestMatches(
                pbkdf2SHA256(password: password, salt: salt, iterations: iterations, keyLength: 32).hexString,
                expected
            )
        }

        // Legacy MODO app-lock verifier. Kept only so existing workspaces can be
        // unlocked once and upgraded in-place to PBKDF2.
        return secureDigestMatches(legacyPasswordDigest(password: password, saltHex: saltHex), expected)
    }

    private func secureDigestMatches(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }

    private func legacyPasswordDigest(password: String, saltHex: String) -> String {
        var payload = Data((saltHex + "|" + password).utf8)
        for _ in 0..<40_000 { payload = Data(SHA256.hash(data: payload)) }
        return payload.hexString
    }

    private func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        let blockLength = 32
        let blockCount = Int(ceil(Double(keyLength) / Double(blockLength)))
        var output = Data()
        output.reserveCapacity(blockCount * blockLength)

        for blockIndex in 1...blockCount {
            var index = UInt32(blockIndex).bigEndian
            var input = Data(salt)
            withUnsafeBytes(of: &index) { input.append(contentsOf: $0) }

            var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: passwordKey))
            var t = [UInt8](u)

            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                    let bytes = [UInt8](u)
                    for i in 0..<t.count { t[i] ^= bytes[i] }
                }
            }
            output.append(contentsOf: t)
        }

        return output.prefix(keyLength)
    }

    private func upgradeLegacyPasswordIfNeeded(_ password: String, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].isPasswordProtected,
              profiles[index].passwordKDF == nil else { return }
        var upgraded = profiles[index]
        applyPassword(password, to: &upgraded)
        profiles[index] = upgraded
        persistProfileSecurity(upgraded)
    }

    private var notificationStateURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("notifications.json")
    }

    private func loadNotificationState() {
        guard let data = try? Data(contentsOf: notificationStateURL),
              let state = try? decoder.decode(FramoNotificationState.self, from: data) else { return }
        notificationState = state
    }

    private func saveNotificationState() {
        guard !isLoading, let data = try? encoder.encode(notificationState) else { return }
        do { try data.write(to: notificationStateURL, options: .atomic) }
        catch { lastFileLinkMessage = "Couldn’t save notification preferences" }
    }

    var visibleNotifications: [FramoNotificationItem] {
        notificationState.items.filter { item in
            guard !item.isDismissed else { return false }
            switch item.kind {
            case .task:
                guard isDestinationEnabled(.tasks),
                      notificationState.tasksEnabled,
                      let task = tasks.first(where: { $0.id == item.taskID }),
                      !task.isComplete, let due = task.dueDate else { return false }
                return item.id == "task-\(task.id)-\(Int(due.timeIntervalSince1970))"
            case .event:
                guard isDestinationEnabled(.calendar),
                      notificationState.eventsEnabled,
                      let event = events.first(where: { $0.id == item.eventID }) else { return false }
                return item.id == "event-\(event.id)-\(Int(event.date.timeIntervalSince1970))"
            case .information: return notificationState.messagesEnabled
            }
        }.sorted { $0.date > $1.date }
    }

    var unreadNotificationCount: Int { visibleNotifications.filter { !$0.isRead }.count }

    func refreshNotifications(now: Date = .now) {
        guard !isLoading else { return }
        var state = notificationState
        let calendar = Calendar.current
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        for task in tasks where !task.isComplete {
            guard isDestinationEnabled(.tasks), state.tasksEnabled, let due = task.dueDate, due < endOfToday else { continue }
            let key = "task-\(task.id)-\(Int(due.timeIntervalSince1970))"
            let overdue = !calendar.isDateInToday(due) && due < now
            let prefix = overdue ? "Overdue task: " : "Task due today: "
            let item = FramoNotificationItem(id: key, kind: .task, title: prefix + task.title,
                date: due, detail: overdue ? "Overdue" : "Due today", taskID: task.id,
                projectID: task.projectID)
            if let index = state.items.firstIndex(where: { $0.id == key }) {
                state.items[index].title = item.title
                state.items[index].detail = item.detail
            } else { state.items.append(item) }
        }
        for event in events {
            guard isDestinationEnabled(.calendar), state.eventsEnabled, event.date >= now, event.date < now.addingTimeInterval(24 * 3600) else { continue }
            let key = "event-\(event.id)-\(Int(event.date.timeIntervalSince1970))"
            let time = event.date.formatted(date: .omitted, time: .shortened)
            let detail = event.location.isEmpty ? time : time + " · " + event.location
            if let index = state.items.firstIndex(where: { $0.id == key }) {
                state.items[index].title = "Coming up: " + event.title
                state.items[index].detail = detail
            } else {
                state.items.append(FramoNotificationItem(id: key, kind: .event,
                    title: "Coming up: " + event.title, date: event.date, detail: detail,
                    eventID: event.id, projectID: event.projectID))
            }
        }
        // Avoid publishing and writing an unchanged inbox on every minute tick.
        if (try? encoder.encode(state)) != (try? encoder.encode(notificationState)) { notificationState = state }
    }

    private func recordNotificationMessage(_ message: String) {
        let now = Date()
        if let last = notificationState.items.last,
           last.kind == .information, last.title == message, now.timeIntervalSince(last.date) < 60 { return }
        notificationState.items.append(FramoNotificationItem(id: UUID().uuidString,
            kind: .information, title: message, date: now))
    }

    func markAllNotificationsRead() {
        let visibleIDs = Set(visibleNotifications.map(\.id))
        var state = notificationState
        for index in state.items.indices where visibleIDs.contains(state.items[index].id) {
            state.items[index].isRead = true
        }
        notificationState = state
    }

    func dismissNotification(_ id: String) {
        guard let index = notificationState.items.firstIndex(where: { $0.id == id }) else { return }
        notificationState.items[index].isDismissed = true
        notificationState.items[index].isRead = true
    }

    func openNotification(_ item: FramoNotificationItem, completeTask: Bool = false) {
        if let index = notificationState.items.firstIndex(where: { $0.id == item.id }) {
            notificationState.items[index].isRead = true
        }
        showNotificationCenter = false
        switch item.kind {
        case .task:
            if completeTask, let id = item.taskID,
               let task = tasks.first(where: { $0.id == id }), !task.isComplete { toggleTask(id) }
            if let id = item.projectID, projects.contains(where: { $0.id == id }) {
                openProjectSection(id, section: .tasks)
            } else { openDestination(.tasks) }
        case .event:
            if let id = item.projectID, projects.contains(where: { $0.id == id }) {
                openProjectSection(id, section: .schedule)
            } else { openDestination(.calendar) }
        case .information: break
        }
    }

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else {
            // First launch only. A missing database is not the same thing as a corrupt one.
            seedPreviewData()
            return
        }

        do {
            let data = try Data(contentsOf: databaseURL)
            let database = try decoder.decode(StudioDatabase.self, from: data)
            applyDatabase(database)
            repairWorkspaceRelationships()
            rebaseManagedMediaReferencesToCurrentRoot()
        } catch {
            preserveFailedWorkspaceCopy()
            if let recovered = loadPreviousValidDatabase() {
                applyDatabase(recovered)
                repairWorkspaceRelationships()
                rebaseManagedMediaReferencesToCurrentRoot()
                workspaceRecoveryNotice = "MODO could not open the newest workspace file, so it restored the previous valid local snapshot. The failed file was preserved in the Recovery folder."
                backupStatus = "Recovered previous workspace"
            } else {
                // Never replace a real but unreadable workspace with demo content.
                projects = []
                tasks = []
                events = []
                spaces = []
                places = []
                invoices = []
                business = ModoBusinessState()
                settings = StudioSettings()
                workspaceRecoveryNotice = "MODO could not open this workspace. The unreadable database was preserved in the Recovery folder and MODO opened an empty recovery workspace instead of overwriting it with demo data."
                backupStatus = "Workspace recovery required"
            }
        }
        migrateProjectEmojis()
    }

    private func applyDatabase(_ database: StudioDatabase) {
        projects = database.projects
        tasks = database.tasks
        events = database.events
        settings = database.settings
        spaces = database.spaces ?? defaultSpaces(for: database.projects)
        places = database.places ?? []
        invoices = database.invoices ?? []
        business = database.business ?? ModoBusinessState()
    }

    private func loadPreviousValidDatabase() -> StudioDatabase? {
        guard let data = try? Data(contentsOf: previousDatabaseURL) else { return nil }
        return try? decoder.decode(StudioDatabase.self, from: data)
    }

    private func preserveFailedWorkspaceCopy() {
        guard let data = try? Data(contentsOf: databaseURL), !data.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = recoveryRootURL.appendingPathComponent("studio-failed-" + formatter.string(from: .now) + ".json")
        try? data.write(to: destination, options: [.atomic])
    }

    private func preserveCurrentDatabaseAsPreviousIfValid() {
        guard let data = try? Data(contentsOf: databaseURL),
              (try? decoder.decode(StudioDatabase.self, from: data)) != nil else { return }
        try? data.write(to: previousDatabaseURL, options: [.atomic])
    }

    func revealRecoveryFolder() {
        NSWorkspace.shared.open(recoveryRootURL)
    }

    func saveNow() {
        guard !isLoading else { return }
        let database = StudioDatabase(projects: projects, tasks: tasks, events: events, settings: settings, spaces: spaces, places: places, invoices: invoices, business: business)
        do {
            let data = try encoder.encode(database)
            preserveCurrentDatabaseAsPreviousIfValid()
            try data.write(to: databaseURL, options: [.atomic])
            scheduleAutomaticBackup()
            if settings.effectiveCloudSyncEnabled && settings.effectiveCloudAutoSyncEnabled && !cloudSync.isApplyingRemote {
                cloudSync.scheduleSync()
            }
        } catch {
            backupStatus = "Couldn’t save workspace"
            pluginNotice = "Workspace save failed: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func scheduleAutomaticBackup() {
        guard !isWritingBackup, settings.autoBackupEnabled == true, settings.backupFolderBookmark != nil else { return }
        automaticBackupTask?.cancel()
        automaticBackupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.performAutomaticBackup(reason: "Saved")
        }
    }

    private func startPeriodicBackupLoop() {
        periodicBackupTask?.cancel()
        periodicBackupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = self.settings.effectiveAutoBackupIntervalMinutes
                try? await Task.sleep(for: .seconds(Double(minutes * 60)))
                guard !Task.isCancelled else { return }
                if self.settings.autoBackupEnabled == true, self.settings.backupFolderBookmark != nil {
                    self.performAutomaticBackup(reason: "Scheduled")
                }
            }
        }
    }

    func requestProjectCreation() {
        guard isDestinationEnabled(.projects) else {
            pluginNotice = "Work is hidden in this workspace. Enable it in Settings → General."
            return
        }
        showProjectCreator = true
    }

    @discardableResult
    func createProject(
        title: String = "Untitled project",
        client: String = "New client",
        kind: ProjectKind = .commercial,
        workType: ModoWorkType? = nil,
        symbol: String? = nil,
        bannerPath: String? = nil,
        bannerAssetName: String? = nil,
        hourlyRate: Double? = nil,
        fixedFee: Double? = nil
    ) -> UUID {
        let resolvedWorkType = workType ?? ModoWorkType.inferred(from: kind)
        let production = resolvedWorkType == .creativeProduction
        let defaultSections = production
            ? (settings.defaultProjectSections ?? resolvedWorkType.defaultSections)
            : resolvedWorkType.defaultSections
        let project = StudioProject(
            title: title.isEmpty ? "Untitled project" : title, client: client.isEmpty ? "New client" : client, description: "Add a concise project description.",
            status: .lead, startDate: .now, dueDate: Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now,
            location: "", colorHex: "9A9A96", coverSymbol: symbol ?? resolvedWorkType.icon, kind: kind, workType: resolvedWorkType, bannerPath: bannerPath,
            editingSoftware: production ? "DaVinci Resolve" : "",
            aspectRatio: production ? "16:9" : "", resolution: production ? "4K UHD" : "", frameRate: production ? "25 fps" : "", brief: "", script: "",
            deliverable: production ? "Final delivery" : "Deliverable", favorite: false, createdAt: .now,
            shots: [], crew: [], kit: [], storyboard: [], timeEntries: [], hourlyRate: hourlyRate, fixedFee: fixedFee,
            ownerName: settings.ownerName.isEmpty ? nil : settings.ownerName,
            enabledSections: defaultSections, clientContacts: [], bannerAssetName: bannerAssetName
        )
        projects.insert(project, at: 0)
        pinProject(project.id)
        selectedProjectID = project.id
        selectedSpaceID = nil
        selection = .projects
        showProjectCreator = false
        recordBusinessActivity(kind: .created, summary: "Work \(project.title) created", recordType: "project", recordID: project.id)
        return project.id
    }

    func deleteProject(_ id: UUID) {
        if activeTimerProjectID == id { stopTimer() }
        projects.removeAll { $0.id == id }
        events.removeAll { $0.projectID == id }
        tasks.removeAll { $0.projectID == id }
        for index in spaces.indices { spaces[index].projectIDs.removeAll { $0 == id } }
        for index in places.indices { places[index].projectIDs.removeAll { $0 == id } }
        closeProjectTab(id)
        unpinProjectFromSidebar(id)
        projectSectionSelection[id] = nil
        if selectedProjectID == id { selectedProjectID = nil }
        if duoProjectID == id { duoProjectID = nil }
        cleanupOrphanedManagedMedia()
    }

    func quickAddTask(projectID: UUID? = nil) {
        guard isDestinationEnabled(.tasks) else {
            pluginNotice = "Tasks are hidden in this workspace. Enable them in Settings → General."
            return
        }
        addTask(title: "New task", dueDate: nil, projectID: projectID)
    }

    func addTask(title: String, dueDate: Date?, projectID: UUID?) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let task = StudioTask(title: cleaned, dueDate: dueDate, projectID: projectID)
        tasks.insert(task, at: 0)
        recordBusinessActivity(kind: .created, summary: "Task \(cleaned) created", recordType: "task", recordID: task.id, related: projectID.map { [$0] } ?? [])
    }

    func updateTask(_ task: StudioTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let wasComplete = tasks[index].isComplete
        tasks[index] = task
        if wasComplete != task.isComplete {
            recordBusinessActivity(
                kind: .statusChanged,
                summary: task.isComplete ? "Task \(task.title) completed" : "Task \(task.title) reopened",
                recordType: "task",
                recordID: task.id,
                related: task.projectID.map { [$0] } ?? []
            )
        }
    }

    func setTaskDueDate(_ id: UUID, date: Date?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].dueDate = date
    }

    var calendarItems: [StudioEvent] {
        let taskEvents = tasks.compactMap { task -> StudioEvent? in
            guard let due = task.dueDate else { return nil }
            let project = task.projectID.flatMap { id in projects.first(where: { $0.id == id }) }
            return StudioEvent(title: task.title, date: due, endDate: due.addingTimeInterval(1800), projectID: task.projectID, location: "Task due", colorHex: project?.colorHex ?? "81817E")
        }
        let projectDates = projects.flatMap { project -> [StudioEvent] in
            let start = StudioEvent(title: project.title, date: project.startDate, endDate: project.startDate.addingTimeInterval(1800), projectID: project.id, location: "Project starts", colorHex: project.colorHex)
            let deadline = StudioEvent(title: project.title, date: project.dueDate, endDate: project.dueDate.addingTimeInterval(1800), projectID: project.id, location: "Project deadline", colorHex: project.colorHex)
            return [start, deadline]
        }
        return (events + taskEvents + projectDates).sorted { $0.date < $1.date }
    }

    func addEvent(projectID: UUID?, on date: Date = .now) {
        createEvent(title: "New event", start: date, end: date.addingTimeInterval(3600), projectID: projectID, location: "")
    }

    private static let calendarPalette = ["547AA5", "4B8C75", "A36E57", "7A68A6", "A47C43", "9A6275", "5E858C"]

    private func automaticCalendarColor(for title: String) -> String {
        let value = title.unicodeScalars.reduce(0) { (($0 &* 31) &+ Int($1.value)) & 0x7fffffff }
        return Self.calendarPalette[value % Self.calendarPalette.count]
    }

    func createEvent(title: String, start: Date, end: Date, projectID: UUID?, location: String = "", colorHex: String? = nil) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let project = projectID.flatMap { id in projects.first(where: { $0.id == id }) }
        let safeEnd = max(end, start.addingTimeInterval(1800))
        let resolvedColor = colorHex ?? project?.colorHex ?? automaticCalendarColor(for: cleaned)
        events.append(StudioEvent(title: cleaned, date: start, endDate: safeEnd, projectID: projectID, location: location, colorHex: resolvedColor))
    }

    func inspectCalendarItem(_ item: StudioEvent) {
        inspectedCalendarItem = item
    }

    func setCalendarItemColor(_ item: StudioEvent, colorHex: String) {
        if let index = events.firstIndex(where: { $0.id == item.id }) {
            events[index].colorHex = colorHex
            inspectedCalendarItem = events[index]
            return
        }
        if let projectID = item.projectID,
           let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].colorHex = colorHex
            var updated = item
            updated.colorHex = colorHex
            inspectedCalendarItem = updated
        }
    }

    func setProjectStatus(_ projectID: UUID, status: ProjectStatus) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].status = status
    }

    func connectAppleCalendar() {
        Task {
            let granted = await calendarBridge.requestAccess()
            calendarIntegrationStatus = granted ? "Apple Calendar connected" : "Calendar access denied"
        }
    }

    func pushFramoPlansToAppleCalendar() {
        Task {
            guard await calendarBridge.requestAccess() else {
                calendarIntegrationStatus = "Calendar access denied"
                return
            }
            do {
                let identifiers = try calendarBridge.upsert(events: events)
                for index in events.indices {
                    if let identifier = identifiers[events[index].id] {
                        events[index].appleEventIdentifier = identifier
                    }
                }
                calendarIntegrationStatus = "Synced \(events.count) MODO plans with Apple Calendar"
            } catch {
                calendarIntegrationStatus = "Calendar sync failed: \(error.localizedDescription)"
            }
        }
    }

    func importAppleCalendar(days: Int = 90) {
        Task {
            guard await calendarBridge.requestAccess() else {
                calendarIntegrationStatus = "Calendar access denied"
                return
            }
            let start = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
            let end = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now.addingTimeInterval(7_776_000)
            let imported = calendarBridge.events(from: start, to: end)
            var existingIdentifiers = Set(events.compactMap(\.appleEventIdentifier))
            var existingKeys = Set(events.map { "\($0.title)|\(Int($0.date.timeIntervalSince1970 / 60))" })
            var added = 0
            for item in imported {
                if let identifier = item.appleEventIdentifier, existingIdentifiers.contains(identifier) { continue }
                let key = "\(item.title)|\(Int(item.date.timeIntervalSince1970 / 60))"
                guard !existingKeys.contains(key) else { continue }
                events.append(item)
                if let identifier = item.appleEventIdentifier { existingIdentifiers.insert(identifier) }
                existingKeys.insert(key)
                added += 1
            }
            calendarIntegrationStatus = "Imported \(added) Apple Calendar event\(added == 1 ? "" : "s")"
        }
    }

    func pinProject(_ id: UUID) {
        var ids = settings.pinnedProjectIDs ?? []
        if !ids.contains(id) { ids.append(id) }
        settings.pinnedProjectIDs = Array(ids.suffix(14))
    }

    func closeProjectTab(_ id: UUID) {
        settings.pinnedProjectIDs?.removeAll { $0 == id }
        settings.fixedProjectTabIDs?.removeAll { $0 == id }
        if duoProjectID == id { duoProjectID = nil }
        if selectedProjectID == id {
            if let nextID = (settings.pinnedProjectIDs ?? []).last {
                apply(.project(nextID))
            } else {
                apply(.destination(.home))
            }
        }
    }

    func setProjectTabPinned(_ id: UUID, pinned: Bool) {
        pinProject(id)
        var ids = settings.fixedProjectTabIDs ?? []
        ids.removeAll { $0 == id }
        if pinned { ids.append(id) }
        settings.fixedProjectTabIDs = ids
    }

    func isProjectTabPinned(_ id: UUID) -> Bool {
        settings.fixedProjectTabIDs?.contains(id) == true
    }

    func pinProjectToSidebar(_ id: UUID) {
        var ids = settings.sidebarProjectIDs ?? []
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        settings.sidebarProjectIDs = Array(ids.prefix(8))
    }

    func unpinProjectFromSidebar(_ id: UUID) {
        settings.sidebarProjectIDs?.removeAll { $0 == id }
    }

    func isProjectPinnedToSidebar(_ id: UUID) -> Bool {
        settings.sidebarProjectIDs?.contains(id) == true
    }

    func pinPage(_ page: SidebarDestination) {
        guard isDestinationEnabled(page) else {
            pluginNotice = "\(page.displayName) is hidden in this workspace."
            return
        }
        var pages = settings.pinnedPages ?? []
        pages.removeAll { $0 == page }
        pages.append(page)
        settings.pinnedPages = Array(pages.suffix(6))
    }

    func unpinPage(_ page: SidebarDestination) {
        settings.pinnedPages?.removeAll { $0 == page }
    }

    var pinnedPages: [SidebarDestination] {
        (settings.pinnedPages ?? []).filter { isDestinationEnabled($0) }
    }

    func unpinProject(_ id: UUID) {
        closeProjectTab(id)
    }

    var pinnedProjects: [StudioProject] {
        guard isDestinationEnabled(.projects) else { return [] }
        let open = settings.pinnedProjectIDs ?? []
        let fixed = settings.fixedProjectTabIDs ?? []
        let ordered = fixed + open.filter { !fixed.contains($0) }
        return ordered.compactMap { id in projects.first(where: { $0.id == id }) }
    }

    var sidebarProjects: [StudioProject] {
        guard isDestinationEnabled(.projects) else { return [] }
        return (settings.sidebarProjectIDs ?? []).compactMap { id in projects.first(where: { $0.id == id }) }
    }

    func toggleTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isComplete.toggle()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func isModuleEnabled(_ destination: SidebarDestination) -> Bool {
        settings.isModuleEnabled(destination)
    }

    func isDestinationEnabled(_ destination: SidebarDestination) -> Bool {
        settings.isDestinationEnabled(destination)
    }

    func openDestination(_ destination: SidebarDestination) {
        let resolved = isDestinationEnabled(destination) ? destination : .home
        navigate(to: .destination(resolved))
    }

    func openProject(_ id: UUID) {
        guard isDestinationEnabled(.projects) else {
            openDestination(.home)
            pluginNotice = "Work is hidden in this workspace."
            return
        }
        pinProject(id)
        if projectSectionSelection[id] == nil { projectSectionSelection[id] = .overview }
        navigate(to: .project(id))
    }

    func openProjectSection(_ id: UUID, section: ProjectSection) {
        guard isDestinationEnabled(.projects) else {
            openDestination(.home)
            return
        }
        if section == .tasks, !isDestinationEnabled(.tasks) {
            projectSectionSelection[id] = .overview
        } else {
            projectSectionSelection[id] = section
        }
        pinProject(id)
        navigate(to: .project(id))
    }

    func selectedSection(for projectID: UUID) -> ProjectSection {
        projectSectionSelection[projectID] ?? .overview
    }

    func setSelectedSection(_ section: ProjectSection, for projectID: UUID) {
        projectSectionSelection[projectID] = section
    }

    func setProjectSectionEnabled(projectID: UUID, section: ProjectSection, enabled: Bool) {
        guard section != .overview, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var sections = projects[index].enabledSections ?? ProjectSection.defaultEnabled
        if enabled && !sections.contains(section) { sections.append(section) }
        if !enabled { sections.removeAll { $0 == section } }
        projects[index].enabledSections = sections
        if !projects[index].effectiveSections.contains(selectedSection(for: projectID)) {
            projectSectionSelection[projectID] = .overview
        }
    }

    func openInDuo(_ id: UUID) {
        guard selectedProjectID != nil, selectedProjectID != id else { return }
        pinProject(id)
        duoProjectID = id
        if projectSectionSelection[id] == nil { projectSectionSelection[id] = .overview }
    }

    func closeDuo() {
        duoProjectID = nil
    }

    func openSpace(_ id: UUID) {
        navigate(to: .space(id))
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(currentTarget)
        apply(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(currentTarget)
        apply(target)
    }

    private var currentTarget: NavigationTarget {
        if let id = selectedSpaceID { return .space(id) }
        if let id = selectedProjectID { return .project(id) }
        return .destination(selection)
    }

    private func navigate(to target: NavigationTarget) {
        let current = currentTarget
        guard current != target else { return }
        backStack.append(current)
        if backStack.count > 40 { backStack.removeFirst(backStack.count - 40) }
        forwardStack.removeAll()
        apply(target)
    }

    private func apply(_ target: NavigationTarget) {
        switch target {
        case .destination(let destination):
            duoProjectID = nil
            selectedProjectID = nil
            selectedSpaceID = nil
            selection = destination
        case .project(let id):
            selectedProjectID = id
            selectedSpaceID = nil
            selection = .projects
        case .space(let id):
            duoProjectID = nil
            selectedSpaceID = id
            selectedProjectID = nil
        }
    }

    func createSpace() {
        let space = StudioSpace(title: "New space", subtitle: "A home for related work", emoji: "square.stack.3d.up", colorHex: "7D9990", bannerPath: nil, projectIDs: [], notes: "")
        spaces.append(space)
        openSpace(space.id)
    }

    func updateProject(_ project: StudioProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
    }

    /// Applies a CloudKit merge as one local transaction. Suppressing normal
    /// didSet saves here prevents a downloaded batch from scheduling dozens of
    /// redundant JSON writes and follow-up cloud syncs.
    func applyCloudCollections(
        projects: [StudioProject],
        tasks: [StudioTask],
        events: [StudioEvent],
        spaces: [StudioSpace],
        places: [StudioPlace],
        invoices: [ModoInvoice],
        business: ModoBusinessState
    ) {
        let previousLoading = isLoading
        isLoading = true
        self.projects = projects
        self.tasks = tasks
        self.events = events
        self.spaces = spaces
        self.places = places
        self.invoices = invoices
        self.business = business
        isLoading = previousLoading
        projectRefreshToken = UUID()
        saveNow()
    }

    func startTimer(for projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        if activeTimerProjectID == projectID {
            if activeTimerStartedAt == nil { activeTimerStartedAt = .now }
            return
        }
        stopTimer()
        focusSessionSeconds = 0
        activeTimerProjectID = projectID
        activeTimerStartedAt = .now
    }

    /// Commit the running segment before pausing, so paused time is never billed.
    func pauseTimer() {
        guard let projectID = activeTimerProjectID, let started = activeTimerStartedAt else { return }
        let seconds = max(0, Date().timeIntervalSince(started))
        focusSessionSeconds += seconds
        activeTimerStartedAt = nil
        commitFocusSegment(projectID: projectID, started: started, seconds: seconds)
    }

    func stopTimer() {
        pauseTimer()
        activeTimerProjectID = nil
        focusSessionSeconds = 0
    }

    func focusElapsedSeconds(now: Date = .now) -> TimeInterval {
        guard activeTimerProjectID != nil else { return 0 }
        guard let started = activeTimerStartedAt else { return focusSessionSeconds }
        return focusSessionSeconds + max(0, now.timeIntervalSince(started))
    }

    private func commitFocusSegment(projectID: UUID, started: Date, seconds: TimeInterval) {
        guard seconds > 0, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].timeEntries.insert(
            TimeEntry(title: "Focus session", date: started, seconds: seconds, billable: true), at: 0
        )
        projectRefreshToken = UUID()
    }

    func effectiveHourlyRate(for project: StudioProject) -> Double {
        let value = project.hourlyRate ?? settings.defaultRate
        return max(0, value)
    }

    func loggedSeconds(for project: StudioProject, includingActive: Bool = true, now: Date = .now) -> TimeInterval {
        var seconds = project.timeEntries.reduce(0) { partial, entry in
            partial + (entry.billable ? max(0, entry.seconds) : 0)
        }
        if includingActive, activeTimerProjectID == project.id, let started = activeTimerStartedAt {
            seconds += max(0, now.timeIntervalSince(started))
        }
        return seconds
    }

    func trackedValue(for project: StudioProject, now: Date = .now) -> Double {
        (loggedSeconds(for: project, includingActive: true, now: now) / 3600) * effectiveHourlyRate(for: project)
    }

    func setWorkspaceMode(_ mode: ModoWorkspaceMode) {
        settings.workspaceMode = mode
        if !settings.effectiveVisibleDestinations.contains(selection) {
            openDestination(.home)
        }
    }

    func createInvoice(projectID: UUID? = nil) -> UUID {
        let year = Calendar.current.component(.year, from: .now)
        let sequence = invoices.count + 1
        let project = projectID.flatMap { id in projects.first(where: { $0.id == id }) }
        let customer = project?.customerID.flatMap { id in business.organizations.first(where: { $0.id == id }) }
        let invoice = ModoInvoice(
            invoiceNumber: String(format: "%d-%04d", year, sequence),
            projectID: projectID,
            customerID: customer?.id,
            quoteID: project?.originatingQuoteID,
            customerName: customer?.name ?? project?.client ?? "",
            customerEmail: customer?.email ?? "",
            customerStreet: customer?.street ?? "",
            customerZip: customer?.postalCode ?? "",
            customerCity: customer?.city ?? "",
            customerCountryCode: customer?.countryCode ?? "BE",
            customerPeppolID: customer?.peppolID ?? "",
            currency: settings.currency
        )
        invoices.insert(invoice, at: 0)
        return invoice.id
    }

    func updateInvoice(_ invoice: ModoInvoice) {
        guard let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
        let existing = invoices[index]
        var value = invoice

        // Once an invoice has been issued, its commercial content is immutable.
        // Transport/payment state may continue to change, but edits to the party,
        // dates, lines, totals and notes cannot silently rewrite issued history.
        if existing.issuedAt != nil || existing.issuedSnapshot != nil {
            value.invoiceNumber = existing.invoiceNumber
            value.projectID = existing.projectID
            value.customerID = existing.customerID
            value.quoteID = existing.quoteID
            value.issueDate = existing.issueDate
            value.dueDate = existing.dueDate
            value.customerName = existing.customerName
            value.customerEmail = existing.customerEmail
            value.customerStreet = existing.customerStreet
            value.customerZip = existing.customerZip
            value.customerCity = existing.customerCity
            value.customerCountryCode = existing.customerCountryCode
            value.customerPeppolScheme = existing.customerPeppolScheme
            value.customerPeppolID = existing.customerPeppolID
            value.currency = existing.currency
            value.lines = existing.lines
            value.notes = existing.notes
            value.issuedAt = existing.issuedAt
            value.issuedSnapshot = existing.issuedSnapshot
        }
        value.updatedAt = .now
        invoices[index] = value
    }

    func deleteInvoice(_ id: UUID) {
        invoices.removeAll { $0.id == id }
    }

    func markInvoicePaid(_ id: UUID) {
        guard let index = invoices.firstIndex(where: { $0.id == id }) else { return }
        invoices[index].status = .paid
        invoices[index].updatedAt = .now
    }

    func fixedFeeBalance(for project: StudioProject, now: Date = .now) -> Double? {
        guard let fixedFee = project.fixedFee, fixedFee > 0 else { return nil }
        return fixedFee - trackedValue(for: project, now: now)
    }

    func setProjectTimePricing(projectID: UUID, hourlyRate: Double?, fixedFee: Double?) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].hourlyRate = hourlyRate
        projects[index].fixedFee = fixedFee
        projectRefreshToken = UUID()
    }

    func exportBackup() -> URL? {
        exportFramo()
    }

    func workspaceData() -> Data? {
        let database = StudioDatabase(projects: projects, tasks: tasks, events: events, settings: settings, spaces: spaces, places: places, invoices: invoices, business: business)
        return try? encoder.encode(database)
    }

    func exportFramo() -> URL? {
        saveNow()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MODO-Workspace.framo")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: databaseURL, to: destination)
            settings.lastBackupDate = .now
            return destination
        } catch { return nil }
    }



    func importFramo(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        try importFramo(data: data)

        // Automatic backups keep Managed Media beside the snapshot folder.
        // Restore it when present, then rebase old absolute Application Support paths
        // to this Mac's current MODO Managed Media directory.
        if let backupMedia = managedMediaBackupBesideWorkspace(url) {
            do {
                try restoreManagedMediaBackup(from: backupMedia)
                rebaseManagedMediaReferencesToCurrentRoot()
                saveNow()
                pluginNotice = "Workspace and managed media restored"
            } catch {
                pluginNotice = "Workspace restored, but some managed media could not be copied: \(error.localizedDescription)"
            }
        } else {
            rebaseManagedMediaReferencesToCurrentRoot()
            saveNow()
        }
    }

    func importFramo(data: Data) throws {
        let database = try decoder.decode(StudioDatabase.self, from: data)
        isLoading = true
        applyDatabase(database)
        repairWorkspaceRelationships()
        migrateProjectEmojis()
        migrateLegacySecretsToKeychain()
        isLoading = false
        saveNow()
    }

    func setLocalTransferEnabled(_ enabled: Bool) {
        settings.localTransferEnabled = enabled
        enabled ? localTransfer.start() : localTransfer.stop()
    }

    func sendWorkspace(to peer: MCPeerID) {
        guard let url = exportFramo() else { return }
        localTransfer.sendFile(url: url, to: peer)
    }

    // MARK: - Plugins

    var pluginCatalog: [FramoPluginManifest] {
        pluginManager.catalog
    }

    func isPluginInstalled(_ id: String) -> Bool {
        settings.effectiveInstalledPluginIDs.contains(id)
    }

    func isPluginEnabled(_ id: String) -> Bool {
        isPluginInstalled(id) && !settings.effectiveDisabledPluginIDs.contains(id)
    }

    func installPlugin(_ id: String) {
        guard pluginManager.canInstall(id) else {
            pluginNotice = "This connector is listed in the marketplace, but its runnable adapter is not implemented yet."
            return
        }
        var installed = settings.effectiveInstalledPluginIDs
        if !installed.contains(id) { installed.append(id) }
        settings.installedPluginIDs = installed
        settings.disabledPluginIDs?.removeAll { $0 == id }
        if id == "org.framo.syncthing" {
            configureFramoV5SyncthingService()
            pluginNotice = "Syncthing added · connect or manage its runtime from Plugins."
            Task { await syncthing.refresh() }
        } else if pluginManager.isRuntimeReady(id) {
            pluginNotice = "Plugin ready · \(pluginManager.runtimeStatus(for: id))"
        } else {
            pluginNotice = "Plugin added · its local runtime still needs to be installed or located."
        }
    }

    func uninstallPlugin(_ id: String) {
        settings.installedPluginIDs?.removeAll { $0 == id }
        settings.disabledPluginIDs?.removeAll { $0 == id }
        if id == "org.framo.syncthing" { syncthing.stopManaged() }
        if !pluginManager.isBuiltIn(id) { pluginManager.removeExternalPlugin(id: id) }
    }

    func setPluginEnabled(_ id: String, enabled: Bool) {
        var disabled = settings.effectiveDisabledPluginIDs
        disabled.removeAll { $0 == id }
        if !enabled { disabled.append(id) }
        settings.disabledPluginIDs = disabled
        if id == "org.framo.syncthing", !enabled { syncthing.stopManaged() }
    }

    func openPluginSettings() {
        requestedSettingsPane = "Plugins"
        openDestination(.settings)
    }

    func installExternalPluginPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose a .framo-plugin package folder containing manifest.json. Plugins run outside the MODO process."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preview = try pluginManager.inspectPackage(at: url)
            let alert = NSAlert()
            alert.messageText = "Install \(preview.name)?"
            let permissions = preview.permissions.isEmpty ? "No MODO permissions requested." : "Permissions: " + preview.permissions.map(\.rawValue).joined(separator: ", ")
            alert.informativeText = "\(preview.summary)\n\n\(permissions)\n\nOnly install plugin packages you trust. Community plugins run as separate processes inside MODO's sandbox."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let manifest = try pluginManager.installPackage(from: url)
            installPlugin(manifest.id)
            pluginNotice = "Installed \(manifest.name) \(manifest.version). Review its permissions in Settings → Plugins."
        } catch {
            pluginNotice = "Plugin install failed: \(error.localizedDescription)"
        }
    }

    func pluginActions(target: PluginTarget, fileExtension: String? = nil) -> [RegisteredPluginAction] {
        pluginManager.actions(
            installedIDs: settings.effectiveInstalledPluginIDs,
            disabledIDs: settings.effectiveDisabledPluginIDs,
            target: target,
            fileExtension: fileExtension
        )
    }

    func runPluginAction(_ registered: RegisteredPluginAction, projectID: UUID? = nil, linkedFileID: UUID? = nil, taskID: UUID? = nil) {
        let project = projectID.flatMap { id in projects.first(where: { $0.id == id }) }
        let linkedFile = project?.linkedFiles?.first(where: { $0.id == linkedFileID })
        let url = linkedFile.flatMap { resolvedURL(for: $0) }
        var context = PluginInvocationContext(
            target: linkedFileID != nil ? .linkedFile : (taskID != nil ? .task : .project),
            projectID: projectID,
            projectTitle: project?.title,
            linkedFileID: linkedFileID,
            taskID: taskID,
            paths: url.map { [$0.path] } ?? [],
            fileNames: linkedFile.map { [$0.displayName] } ?? []
        )

        if registered.plugin.id == "org.framo.taskkit" {
            runTaskKitAction(registered.action.id, taskID: taskID)
            return
        }
        if registered.plugin.id == "org.framo.calendar-kit" {
            runCalendarKitAction(registered.action.id, projectID: projectID)
            return
        }
        if registered.plugin.id == "org.framo.syncthing" {
            runSyncthingAction(registered.action.id, projectID: projectID, linkedFile: linkedFile)
            return
        }

        let fileToolIDs = ["org.framo.ffmpeg", "org.framo.mediainfo", "org.framo.exiftool", "org.framo.imagemagick", "org.framo.checksum", "org.framo.archive", "org.framo.otio", "org.framo.finder", "org.framo.rsync", "org.framo.webtorrent", "org.framo.quicklook", "org.framo.spotlight"]
        if fileToolIDs.contains(registered.plugin.id) {
            guard let url else { pluginNotice = "This plugin action needs a linked file."; return }
            let accessed = url.startAccessingSecurityScopedResource()
            pluginManager.runBuiltInTool(pluginID: registered.plugin.id, actionID: registered.action.id, url: url) { [weak self] message in
                DispatchQueue.main.async {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                    self?.pluginNotice = message
                }
            }
            return
        }

        if registered.plugin.id == "org.framo.native-export" {
            guard let project else { pluginNotice = "Open a project first."; return }
            runNativeExportAction(registered.action.id, project: project)
            return
        }

        if ["org.framo.rclone", "org.framo.restic", "org.framo.git", "org.framo.webtorrent"].contains(registered.plugin.id) {
            pluginManager.runProjectUtility(pluginID: registered.plugin.id, actionID: registered.action.id) { [weak self] message in
                DispatchQueue.main.async { self?.pluginNotice = message }
            }
            return
        }

        if !registered.plugin.permissions.contains(.linkedFiles) && !registered.plugin.permissions.contains(.externalVolumes) {
            context.paths = []
            context.fileNames = []
        }
        if !registered.plugin.permissions.contains(.projectData) {
            context.projectID = nil
            context.projectTitle = nil
            context.taskID = nil
        }
        pluginManager.runExternal(plugin: registered.plugin, action: registered.action, context: context) { [weak self] message in
            DispatchQueue.main.async { self?.pluginNotice = message }
        }
    }

    private func runTaskKitAction(_ actionID: String, taskID: UUID?) {
        guard let taskID, let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            pluginNotice = "Select a task first."
            return
        }
        switch actionID {
        case "copy-markdown":
            let task = tasks[index]
            let due = task.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "No deadline"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("- [\(task.isComplete ? "x" : " ")] \(task.title) — \(due)", forType: .string)
            pluginNotice = "Copied task as Markdown."
        case "tomorrow":
            tasks[index].dueDate = Calendar.current.date(byAdding: .day, value: 1, to: .now)
            pluginNotice = "Task deadline set to tomorrow."
        case "toggle":
            tasks[index].isComplete.toggle()
            pluginNotice = tasks[index].isComplete ? "Task completed." : "Task reopened."
        default:
            pluginNotice = "Unknown Task Kit action."
        }
    }

    private func runCalendarKitAction(_ actionID: String, projectID: UUID?) {
        guard let projectID, let project = projects.first(where: { $0.id == projectID }) else {
            pluginNotice = "Open a project first."
            return
        }
        switch actionID {
        case "deadline-event":
            let title = "\(project.title) deadline"
            let alreadyExists = events.contains { $0.projectID == project.id && $0.title == title && abs($0.date.timeIntervalSince(project.dueDate)) < 60 }
            if !alreadyExists {
                createEvent(title: title, start: project.dueDate, end: project.dueDate.addingTimeInterval(3600), projectID: project.id, location: project.location)
            }
            pluginNotice = alreadyExists ? "Deadline is already in MODO Calendar." : "Added project deadline to MODO Calendar."
        case "push-apple":
            pushFramoPlansToAppleCalendar()
            pluginNotice = "Sending MODO plans to Apple Calendar…"
        default:
            pluginNotice = "Unknown Calendar Kit action."
        }
    }

    private func runSyncthingAction(_ actionID: String, projectID: UUID?, linkedFile: LinkedProjectFile?) {
        switch actionID {
        case "configure-project":
            guard let projectID else { return }
            openProjectSection(projectID, section: .files)
            pluginNotice = "Syncthing controls are in this project's Files page. Choose a folder and the devices that should receive it."
        case "rescan-project":
            guard let projectID,
                  let folderID = projects.first(where: { $0.id == projectID })?.syncthingFolderID else {
                pluginNotice = "Configure Syncthing for this project first."
                return
            }
            Task {
                do { try await syncthing.rescan(folderID: folderID); await syncthing.refreshFolderStatus(folderID: folderID); pluginNotice = "Syncthing rescan requested." }
                catch { pluginNotice = "Syncthing rescan failed: \(error.localizedDescription)" }
            }
        case "sync-containing-folder":
            guard let linkedFile, let url = resolvedURL(for: linkedFile) else { return }
            let folder = url.deletingLastPathComponent()
            pluginNotice = "Syncthing syncs folders rather than individual files. Add \(folder.lastPathComponent) as a project sync root from Files → Syncthing."
        default:
            break
        }
    }

    private func runNativeExportAction(_ actionID: String, project: StudioProject) {
        let panel = NSSavePanel()
        let body: String
        let brandName = settings.studioName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "MODO"
            : settings.studioName
        let brandFooter = "\n\n---\nPrepared by \(brandName) with MODO"

        switch actionID {
        case "project-summary":
            panel.nameFieldStringValue = "\(project.title)-summary.md"
            body = """
            # \(brandName)
            ## \(project.title)

            Type: \(project.effectiveWorkType.rawValue)
            Customer: \(project.client)
            Status: \(project.status.displayName(for: project.effectiveWorkType))
            Due: \(project.dueDate.formatted(date: .abbreviated, time: .omitted))

            ## Brief
            \(project.brief)

            ## Notes / Script
            \(project.script)
            """ + brandFooter

        case "shotlist-csv":
            guard project.effectiveWorkType == .creativeProduction else {
                pluginNotice = "Shot-list export is available for creative production work."
                return
            }
            panel.nameFieldStringValue = "\(project.title)-shotlist.csv"
            body = (["Number,Title,Description,Size,Movement,Lens,Frame rate,Duration"] + project.shots.map { shot in
                [String(shot.number), shot.title, shot.description, shot.shotSize, shot.movement, shot.lens, shot.frameRate, shot.duration]
                    .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                    .joined(separator: ",")
            }).joined(separator: "\n")

        case "tasks-csv":
            guard isDestinationEnabled(.tasks) else {
                pluginNotice = "Tasks are disabled for this workspace."
                return
            }
            panel.nameFieldStringValue = "\(project.title)-tasks.csv"
            body = (["Task,Complete,Due"] + tasks.filter { $0.projectID == project.id }.map { task in
                "\"\(task.title.replacingOccurrences(of: "\"", with: "\"\""))\",\(task.isComplete),\(task.dueDate?.formatted(date: .numeric, time: .omitted) ?? "")"
            }).joined(separator: "\n")

        case "call-sheet":
            guard project.effectiveWorkType == .creativeProduction || project.effectiveWorkType == .event else {
                pluginNotice = "Call sheets are available for creative productions and events."
                return
            }
            panel.nameFieldStringValue = "\(project.title)-call-sheet.md"
            let crewLines = project.crew.map { "- \($0.name) — \($0.role) — \($0.email)" }.joined(separator: "\n")
            let kitLines = project.kit.map { "- \($0.name) x\($0.quantity) — \($0.packed ? "packed" : "not packed")" }.joined(separator: "\n")
            body = """
            # \(brandName)
            ## \(project.title) — Call Sheet Draft

            Customer: \(project.client)
            Location: \(project.location)
            Start: \(project.startDate.formatted(date: .abbreviated, time: .shortened))
            Deadline: \(project.dueDate.formatted(date: .abbreviated, time: .shortened))

            ## Crew
            \(crewLines)

            ## Kit
            \(kitLines)
            """ + brandFooter

        case "delivery-manifest":
            panel.nameFieldStringValue = "\(project.title)-delivery-manifest.md"
            let files = (project.linkedFiles ?? [])
                .map { "- \($0.displayName) — \($0.sizeLabel) — \($0.volumeName)" }
                .joined(separator: "\n")
            let formatLine = project.effectiveWorkType == .creativeProduction
                ? "\nFormat: \(project.resolution) · \(project.frameRate) · \(project.aspectRatio)"
                : ""

            body = """
            # \(brandName)
            ## \(project.title) — Delivery Manifest

            Customer: \(project.client)
            Work type: \(project.effectiveWorkType.rawValue)
            Deliverable: \(project.deliverable)\(formatLine)

            ## Linked files
            \(files.isEmpty ? "No linked files" : files)
            """ + brandFooter

        default:
            pluginNotice = "Unknown export action."
            return
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            pluginNotice = "Exported \(url.lastPathComponent)."
        } catch {
            pluginNotice = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Syncthing plugin

    func configureFramoV5SyncthingService() {
        syncthing.configure(baseURL: settings.effectiveSyncthingBaseURL, apiKey: FramoV5Keychain.readSyncthingAPIKey() ?? "")
    }

    func setSyncthingBaseURL(_ value: String) {
        settings.syncthingBaseURL = value
        configureFramoV5SyncthingService()
    }

    func setSyncthingAPIKey(_ value: String) {
        FramoV5Keychain.saveSyncthingAPIKey(value)
        configureFramoV5SyncthingService()
    }

    func chooseSyncthingExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Syncthing"
        panel.message = "Choose the Syncthing executable. MODO can then run an isolated Syncthing instance using its own config directory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            settings.syncthingExecutableBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            settings.syncthingExecutablePath = url.path
        } catch {
            pluginNotice = "Couldn’t remember the Syncthing executable: \(error.localizedDescription)"
        }
    }

    func detectedSyncthingExecutable() -> URL? {
        if let data = settings.syncthingExecutableBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let candidates = [
            "/opt/homebrew/bin/syncthing",
            "/usr/local/bin/syncthing",
            "/Applications/Syncthing.app/Contents/MacOS/syncthing"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func startManagedSyncthing() {
        guard let executable = detectedSyncthingExecutable() else {
            pluginNotice = "Syncthing executable not found. Choose it in Settings → Plugins → Syncthing."
            return
        }
        var apiKey = FramoV5Keychain.readSyncthingAPIKey() ?? ""
        if apiKey.isEmpty {
            apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            FramoV5Keychain.saveSyncthingAPIKey(apiKey)
        }
        let home = databaseURL.deletingLastPathComponent().appendingPathComponent("Plugins/Syncthing", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        settings.syncthingMode = .managed
        settings.syncthingBaseURL = "http://127.0.0.1:8384"
        configureFramoV5SyncthingService()
        do {
            try syncthing.startManaged(executable: executable, home: home, apiKey: apiKey)
            pluginNotice = "MODO started its managed Syncthing instance. It may take a moment to become available."
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                await syncthing.refresh()
            }
        } catch {
            pluginNotice = "Couldn’t start Syncthing: \(error.localizedDescription)"
        }
    }

    func stopManagedSyncthing() {
        syncthing.stopManaged()
    }

    func chooseSyncthingRoot(for projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as sync root"
        panel.message = "Syncthing works on folders. Pick the folder that should stay synchronized for this MODO project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            projects[index].syncthingFolderBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            projects[index].syncthingFolderPath = url.path
            if projects[index].syncthingFolderID == nil {
                projects[index].syncthingFolderID = "framo-" + String(projects[index].id.uuidString.lowercased().prefix(12))
            }
        } catch {
            pluginNotice = "Couldn’t save the sync folder: \(error.localizedDescription)"
        }
    }

    func setSyncthingDevice(_ deviceID: String, selected: Bool, for projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var ids = projects[index].syncthingDeviceIDs ?? []
        ids.removeAll { $0 == deviceID }
        if selected { ids.append(deviceID) }
        projects[index].syncthingDeviceIDs = ids
    }

    func configureProjectSyncthing(_ projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }),
              let path = projects[index].syncthingFolderPath,
              let folderID = projects[index].syncthingFolderID else {
            pluginNotice = "Choose a project sync folder first."
            return
        }
        let label = projects[index].title
        let deviceIDs = projects[index].syncthingDeviceIDs ?? []
        Task {
            do {
                try await syncthing.addOrUpdateFolder(folderID: folderID, label: label, path: path, deviceIDs: deviceIDs)
                await syncthing.refresh()
                await syncthing.refreshFolderStatus(folderID: folderID)
                pluginNotice = deviceIDs.isEmpty ? "Folder added to Syncthing. Select at least one remote device to actually replicate it." : "Syncthing is now keeping this project folder in sync."
            } catch {
                pluginNotice = "Couldn’t configure Syncthing: \(error.localizedDescription)"
            }
        }
    }

    func refreshProjectSyncthing(_ projectID: UUID) {
        guard let folderID = projects.first(where: { $0.id == projectID })?.syncthingFolderID else { return }
        Task { await syncthing.refresh(); await syncthing.refreshFolderStatus(folderID: folderID) }
    }

    // MARK: - Linked production files

    func linkFiles(to projectID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "MODO stores secure references to your media. Files stay on their current drive and are never copied into the project database."
        guard panel.runModal() == .OK else { return }

        let maximumBytes: Int64 = 100 * 1024 * 1024 * 1024
        var linked = projects[projectIndex].linkedFiles ?? []
        var skipped: [String] = []

        for url in panel.urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .volumeNameKey, .contentTypeKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { skipped.append(url.lastPathComponent); continue }
            let byteSize = Int64(values?.fileSize ?? 0)
            guard byteSize <= maximumBytes else { skipped.append("\(url.lastPathComponent) (>100 GB)"); continue }
            guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.fileSizeKey, .volumeNameKey], relativeTo: nil) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            if linked.contains(where: { $0.originalPath == url.path }) { continue }
            linked.append(LinkedProjectFile(
                displayName: url.lastPathComponent,
                bookmarkData: bookmark,
                originalPath: url.path,
                byteSize: byteSize,
                volumeName: values?.volumeName ?? url.deletingLastPathComponent().lastPathComponent,
                contentType: values?.contentType?.identifier ?? "public.data"
            ))
        }
        projects[projectIndex].linkedFiles = linked
        lastFileLinkMessage = skipped.isEmpty ? "Linked \(panel.urls.count) file\(panel.urls.count == 1 ? "" : "s") without copying them." : "Linked what MODO could. Skipped: \(skipped.joined(separator: ", "))."
        refreshHostShareIndex()
    }

    func removeLinkedFile(_ fileID: UUID, from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].linkedFiles?.removeAll { $0.id == fileID }
        refreshHostShareIndex()
    }

    func relinkFile(_ fileID: UUID, in projectID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let fileIndex = projects[projectIndex].linkedFiles?.firstIndex(where: { $0.id == fileID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Choose the moved copy of \(projects[projectIndex].linkedFiles?[fileIndex].displayName ?? "this file")."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .volumeNameKey, .contentTypeKey])
        guard Int64(values?.fileSize ?? 0) <= 100 * 1024 * 1024 * 1024,
              let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        projects[projectIndex].linkedFiles?[fileIndex].displayName = url.lastPathComponent
        projects[projectIndex].linkedFiles?[fileIndex].originalPath = url.path
        projects[projectIndex].linkedFiles?[fileIndex].bookmarkData = bookmark
        projects[projectIndex].linkedFiles?[fileIndex].byteSize = Int64(values?.fileSize ?? 0)
        projects[projectIndex].linkedFiles?[fileIndex].volumeName = values?.volumeName ?? "External drive"
        projects[projectIndex].linkedFiles?[fileIndex].contentType = values?.contentType?.identifier ?? "public.data"
        refreshHostShareIndex()
    }

    func resolvedURL(for linkedFile: LinkedProjectFile) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: linkedFile.bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        let fallback = URL(fileURLWithPath: linkedFile.originalPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    func linkedFileIsAvailable(_ linkedFile: LinkedProjectFile) -> Bool {
        guard let url = resolvedURL(for: linkedFile) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func openLinkedFile(_ linkedFile: LinkedProjectFile) {
        guard let url = resolvedURL(for: linkedFile) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.open(url)
        if accessed { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { url.stopAccessingSecurityScopedResource() } }
    }

    func revealLinkedFile(_ linkedFile: LinkedProjectFile) {
        guard let url = resolvedURL(for: linkedFile) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if accessed { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { url.stopAccessingSecurityScopedResource() } }
    }

    func sendLinkedFile(_ linkedFile: LinkedProjectFile, to peer: MCPeerID) {
        guard let url = resolvedURL(for: linkedFile) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        localTransfer.sendFile(url: url, to: peer) {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
    }

    // MARK: - Self-hosted sharing

    func setHostSharingEnabled(_ enabled: Bool) {
        settings.hostSharingEnabled = enabled
        enabled ? startHostSharing() : hostSharing.stop()
    }

    private var hostAccessToken: String {
        FramoV5Keychain.readHostAccessToken() ?? ""
    }

    private var remoteHostToken: String {
        FramoV5Keychain.readRemoteHostToken() ?? ""
    }

    private func migrateLegacySecretsToKeychain() {
        if let legacy = settings.hostAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty,
           FramoV5Keychain.readHostAccessToken() == nil {
            FramoV5Keychain.saveHostAccessToken(legacy)
        }
        if let legacy = settings.remoteHostToken?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty,
           FramoV5Keychain.readRemoteHostToken() == nil {
            FramoV5Keychain.saveRemoteHostToken(legacy)
        }
        settings.hostAccessToken = nil
        settings.remoteHostToken = nil
    }

    func ensureHostToken() {
        guard hostAccessToken.isEmpty else { return }
        var bytes = [UInt8](repeating: 0, count: 24)
        let token: String
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        if status == errSecSuccess {
            token = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        FramoV5Keychain.saveHostAccessToken(token)
    }

    func startHostSharing() {
        ensureHostToken()
        saveNow()
        hostSharing.start(
            port: settings.effectiveHostPort,
            token: hostAccessToken,
            workspaceURL: databaseURL,
            workspaceName: settings.studioName,
            shares: hostShareDescriptors(),
            shareWorkspace: settings.effectiveHostShareWorkspace,
            shareLinkedFiles: settings.effectiveHostShareLinkedFiles
        )
    }

    func restartHostSharing() {
        guard settings.effectiveHostSharingEnabled else { return }
        hostSharing.stop()
        startHostSharing()
    }

    private func refreshHostShareIndex() {
        guard !isLoading, settings.effectiveHostSharingEnabled else { return }
        hostSharing.updateShares(hostShareDescriptors())
    }

    private func hostShareDescriptors() -> [FramoV5HostedFile] {
        projects.flatMap { project in
            (project.linkedFiles ?? []).map {
                FramoV5HostedFile(id: $0.id, projectID: project.id, projectTitle: project.title, name: $0.displayName, byteSize: $0.byteSize, volumeName: $0.volumeName, bookmarkData: $0.bookmarkData, fallbackPath: $0.originalPath)
            }
        }
    }

    func connectRemoteHost() {
        let host = settings.remoteHostAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = remoteHostToken
        guard !host.isEmpty, !token.isEmpty else { return }
        remoteAccess.connect(host: host, port: settings.effectiveRemoteHostPort, token: token)
    }

    // MARK: - MODO Connect Remote (Tor Onion Service)

    func setFramoConnectRemoteEnabled(_ enabled: Bool) {
        if enabled && !experimentalRemoteConnectEnabled {
            settings.framoConnectRemoteEnabled = false
            pluginNotice = "Remote Connect is experimental and disabled in this release build."
            return
        }
        settings.framoConnectRemoteEnabled = enabled
        if enabled {
            settings.hostSharingEnabled = true
            settings.hostShareWorkspace = true
            startFramoConnectRemote()
        } else {
            torConnect.stop()
        }
    }

    func chooseTorExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Tor"
        panel.message = "Choose a Tor executable. MODO uses it only for MODO Connect Remote."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            pluginNotice = "That file is not executable"
            return
        }
        do {
            settings.framoConnectTorExecutableBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            settings.framoConnectTorExecutablePath = url.path
            if experimentalRemoteConnectEnabled && settings.effectiveFramoConnectRemoteEnabled { startFramoConnectRemote() }
        } catch {
            pluginNotice = "Couldn’t remember the Tor executable: \(error.localizedDescription)"
        }
    }

    func detectedTorExecutable() -> URL? {
        if let data = settings.framoConnectTorExecutableBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "tor", withExtension: nil, subdirectory: "Tor"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if let bundled = Bundle.main.url(forResource: "tor", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let candidates = [
            "/opt/homebrew/bin/tor",
            "/usr/local/bin/tor",
            "/opt/local/bin/tor"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isDevelopmentSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    func isBundledTorExecutable(_ url: URL) -> Bool {
        guard let resources = Bundle.main.resourceURL?.standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(resources)
    }

    var framoConnectTorNeedsSandboxFix: Bool {
        guard isDevelopmentSandboxed, let executable = detectedTorExecutable() else { return false }
        return !isBundledTorExecutable(executable)
    }

    func copyTorInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install tor", forType: .string)
        pluginNotice = "Copied: brew install tor"
    }

    func copyTorDevelopmentFix() {
        let steps = "MODO Connect Remote — Xcode test setup\n1. Open the MODO target in Xcode.\n2. Open Signing & Capabilities.\n3. For local testing, disable/remove App Sandbox so the development build can launch the Homebrew Tor executable.\n4. Build and run again, then open Settings → MODO Connect → Remote.\n\nFor a distributed build, bundle a signed Tor runtime inside MODO instead of requiring users to disable the sandbox."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(steps, forType: .string)
        pluginNotice = "Copied the Xcode Remote setup steps"
    }

    func startFramoConnectRemote() {
        guard experimentalRemoteConnectEnabled else {
            settings.framoConnectRemoteEnabled = false
            torConnect.stop()
            pluginNotice = "Remote Connect is experimental and disabled in this release build."
            return
        }
        ensureHostToken()
        settings.hostSharingEnabled = true
        settings.hostShareWorkspace = true
        startHostSharing()
        guard let executable = detectedTorExecutable() else {
            torConnect.markTorMissing()
            return
        }
        if isDevelopmentSandboxed && !isBundledTorExecutable(executable) {
            torConnect.markSetupIssue("This Xcode build is sandboxed, so macOS is blocking the external Tor executable. Disable App Sandbox for local testing, or bundle Tor inside MODO for release builds.")
            return
        }
        torConnect.start(
            executableURL: executable,
            targetPort: settings.effectiveHostPort,
            socksPort: settings.effectiveFramoConnectSocksPort
        )
    }

    var framoConnectInvite: String? {
        guard let onion = torConnect.onionAddress, !onion.isEmpty, !hostAccessToken.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "framo-connect"
        components.host = "pair"
        components.path = "/v1"
        components.queryItems = [
            URLQueryItem(name: "onion", value: onion),
            URLQueryItem(name: "token", value: hostAccessToken)
        ]
        return components.string
    }

    func copyFramoConnectInvite() {
        guard let invite = framoConnectInvite else {
            pluginNotice = "MODO Connect Remote is not online yet"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite, forType: .string)
        pluginNotice = "MODO Connect invite copied"
    }

    func connectFramoInvite(_ raw: String) {
        guard experimentalRemoteConnectEnabled else {
            pluginNotice = "Remote Connect is experimental and disabled in this release build."
            return
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value), components.scheme == "framo-connect" else {
            pluginNotice = "That isn’t a MODO Connect invite"
            return
        }
        let onion = components.queryItems?.first(where: { $0.name == "onion" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard onion.hasSuffix(".onion"), onion.count > 20, !token.isEmpty else {
            pluginNotice = "The MODO Connect invite is incomplete"
            return
        }
        settings.remoteHostAddress = onion
        FramoV5Keychain.saveRemoteHostToken(token)
        settings.remoteHostPort = 80
        connectFramoOnion(host: onion, token: token)
    }

    func connectFramoOnion(host: String? = nil, token: String? = nil) {
        guard experimentalRemoteConnectEnabled else {
            pluginNotice = "Remote Connect is experimental and disabled in this release build."
            return
        }
        let onion = (host ?? settings.remoteHostAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let accessToken = (token ?? remoteHostToken).trimmingCharacters(in: .whitespacesAndNewlines)
        guard onion.hasSuffix(".onion"), !accessToken.isEmpty else {
            pluginNotice = "Paste a MODO Connect invite first"
            return
        }
        guard torConnect.isRunning else {
            startFramoConnectRemote()
            pluginNotice = "Starting Tor. Connect again when Remote shows Online."
            return
        }
        remoteAccess.connectViaTor(onionHost: onion, token: accessToken, socksPort: settings.effectiveFramoConnectSocksPort)
    }

    func pullRemoteWorkspace() {
        guard let item = remoteAccess.manifest?.items.first(where: { $0.kind == .workspace }) else {
            pluginNotice = "The connected Mac isn’t sharing its workspace"
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MODO-Connect-Remote.framo")
        try? FileManager.default.removeItem(at: url)
        remoteAccess.download(item: item, to: url) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: url)
                    try self.applyRemoteWorkspaceSnapshot(data: data)
                    self.pluginNotice = "Remote workspace pulled into this Mac"
                } catch {
                    self.pluginNotice = "Couldn’t import remote workspace: \(error.localizedDescription)"
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func applyRemoteWorkspaceSnapshot(data: Data) throws {
        let database = try decoder.decode(StudioDatabase.self, from: data)
        let localSettings = settings
        isLoading = true
        projects = database.projects
        tasks = database.tasks
        events = database.events
        spaces = database.spaces ?? defaultSpaces(for: database.projects)
        places = database.places ?? []
        invoices = database.invoices ?? []
        business = database.business ?? ModoBusinessState()
        settings = localSettings
        migrateProjectEmojis()
        isLoading = false
        saveNow()
    }

    func downloadRemoteItem(_ item: FramoV5RemoteItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        remoteAccess.download(item: item, to: url) {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
    }

    func downloadRemoteItemAndLink(_ item: FramoV5RemoteItem, to projectID: UUID) {
        guard item.kind == .linkedFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.prompt = "Download & Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        remoteAccess.download(item: item, to: url) { [weak self] in
            DispatchQueue.main.async {
                if accessed { url.stopAccessingSecurityScopedResource() }
                self?.linkExistingFile(url, to: projectID)
            }
        }
    }

    private func linkExistingFile(_ url: URL, to projectID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .volumeNameKey, .contentTypeKey, .isRegularFileKey])
        let byteSize = Int64(values?.fileSize ?? 0)
        guard values?.isRegularFile != false, byteSize <= 100 * 1024 * 1024 * 1024,
              let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.fileSizeKey, .volumeNameKey], relativeTo: nil) else { return }
        var linked = projects[projectIndex].linkedFiles ?? []
        guard !linked.contains(where: { $0.originalPath == url.path }) else { return }
        linked.append(LinkedProjectFile(displayName: url.lastPathComponent, bookmarkData: bookmark, originalPath: url.path, byteSize: byteSize, volumeName: values?.volumeName ?? url.deletingLastPathComponent().lastPathComponent, contentType: values?.contentType?.identifier ?? "public.data"))
        projects[projectIndex].linkedFiles = linked
        lastFileLinkMessage = "Downloaded and linked \(url.lastPathComponent)."
        refreshHostShareIndex()
    }

    func setBackupFolder(_ url: URL) throws {
        settings.backupFolderBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        settings.backupFolderPath = url.path
        settings.autoBackupEnabled = true
        refreshBackupStatus()
        performAutomaticBackup(reason: "Initial")
    }

    func runBackupNow() {
        performAutomaticBackup(reason: "Manual")
    }

    func updateBackupSchedule(minutes: Int) {
        settings.autoBackupIntervalMinutes = minutes
        startPeriodicBackupLoop()
    }

    private func refreshBackupStatus() {
        guard settings.autoBackupEnabled == true else {
            backupStatus = "Off"
            return
        }
        guard settings.backupFolderBookmark != nil else {
            backupStatus = "Choose a folder"
            return
        }
        if let date = settings.lastBackupDate {
            backupStatus = "Last backup " + date.formatted(date: .abbreviated, time: .shortened)
        } else {
            backupStatus = "Ready"
        }
    }

    private func backupRootURL() -> URL? {
        guard let data = settings.backupFolderBookmark else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return root
    }

    private func performAutomaticBackup(reason: String) {
        guard !isWritingBackup, settings.autoBackupEnabled == true, let root = backupRootURL() else { return }
        automaticBackupTask?.cancel()
        isWritingBackup = true
        backupStatus = "Backing up…"
        let accessed = root.startAccessingSecurityScopedResource()
        defer {
            if accessed { root.stopAccessingSecurityScopedResource() }
            isWritingBackup = false
        }

        do {
            let workspace = root.appendingPathComponent("Bywarre Studio", isDirectory: true)
            let snapshots = workspace.appendingPathComponent("Automatic Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let snapshotURL = snapshots.appendingPathComponent("MODO-" + formatter.string(from: .now) + ".framo")
            let database = StudioDatabase(projects: projects, tasks: tasks, events: events, settings: settings, spaces: spaces, places: places, invoices: invoices, business: business)
            let data = try encoder.encode(database)
            try data.write(to: snapshotURL, options: [.atomic])
            try mirrorManagedMediaBackup(into: workspace.appendingPathComponent("Managed Media", isDirectory: true))
            writeMarkdownBackup(into: workspace)
            pruneAutomaticBackups(in: snapshots)

            let completed = Date.now
            isUpdatingBackupMetadata = true
            settings.lastBackupDate = completed
            isUpdatingBackupMetadata = false
            backupStatus = "Backed up " + completed.formatted(date: .omitted, time: .shortened)
        } catch {
            backupStatus = "Backup failed"
        }
    }

    private func pruneAutomaticBackups(in folder: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let backups = urls.filter { $0.pathExtension.lowercased() == "framo" }.sorted {
            let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for url in backups.dropFirst(settings.effectiveAutoBackupKeepCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func writeMarkdownBackup() {
        guard let root = backupRootURL() else { return }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        let workspace = root.appendingPathComponent("Bywarre Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        writeMarkdownBackup(into: workspace)
    }

    private func writeMarkdownBackup(into workspace: URL) {
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        for project in projects {
            let folder = workspace.appendingPathComponent(safeFilename(project.title), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let typeName = project.kind?.rawValue ?? "Project"
            let frontmatter = "---\ntitle: \(project.title)\nclient: \(project.client)\nstatus: \(project.status.rawValue)\ntype: \(typeName)\ndue: \(project.dueDate.formatted(date: .numeric, time: .omitted))\n---\n\n"
            let frameLinks = [project.frameIOURL.map { "Frame.io: \($0)" }, project.clientShareURL.map { "Client share: \($0)" }].compactMap { $0 }.joined(separator: "\n")
            let linkedIndex = (project.linkedFiles ?? []).map { "- \($0.displayName) — \($0.sizeLabel) — \($0.originalPath)" }.joined(separator: "\n")
            write(frontmatter + "# \(project.title)\n\n\(project.description)\n\n## Deliverables\n\(project.deliverable)\n\n## Review links\n\(frameLinks)\n\n## Linked files\n\(linkedIndex)\n", named: "Overview.md", in: folder)
            write("# Brief\n\n\(project.brief)\n", named: "Brief.md", in: folder)
            write("# Script\n\n\(project.script)\n", named: "Script.md", in: folder)
            write("# Shot list\n\n" + project.shots.map {
                let mark = $0.completed ? "x" : " "
                return "- [\(mark)] **\($0.number). \($0.title)** — \($0.shotSize), \($0.movement), \($0.lens)\n  \($0.description)"
            }.joined(separator: "\n"), named: "Shots.md", in: folder)
            write("# Storyboard\n\n" + project.storyboard.map { "## \($0.shotNumber). \($0.title)\n\($0.notes)" }.joined(separator: "\n\n"), named: "Storyboard.md", in: folder)
            write("# Crew\n\n" + project.crew.map { "- **\($0.name)** — \($0.role) · \($0.email)" }.joined(separator: "\n"), named: "Crew.md", in: folder)
            write("# Kit list\n\n" + project.kit.map {
                let mark = $0.packed ? "x" : " "
                return "- [\(mark)] \($0.quantity)× \($0.name) (\($0.category))"
            }.joined(separator: "\n"), named: "Kit.md", in: folder)
            let projectTasks = tasks.filter { $0.projectID == project.id }
            write("# Tasks\n\n" + projectTasks.map {
                let mark = $0.isComplete ? "x" : " "
                return "- [\(mark)] \($0.title)"
            }.joined(separator: "\n"), named: "Tasks.md", in: folder)
            write("# Time log\n\n" + project.timeEntries.map { "- \($0.date.formatted(date: .abbreviated, time: .shortened)) — \($0.title): \(Int($0.seconds / 60)) min" }.joined(separator: "\n"), named: "Time Log.md", in: folder)
        }

        let index = spaces.map { space in
            let links = space.projectIDs.compactMap { id in projects.first(where: { $0.id == id }) }.map { "- [[\(safeFilename($0.title))/Overview|\($0.title)]]" }.joined(separator: "\n")
            return "## \(space.title)\n\(space.subtitle)\n\n\(links)"
        }.joined(separator: "\n\n")
        write("# Spaces\n\n\(index)\n", named: "Spaces.md", in: workspace)
    }

    private func write(_ text: String, named name: String, in folder: URL) {
        try? text.data(using: .utf8)?.write(to: folder.appendingPathComponent(name), options: [.atomic])
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func migrateProjectEmojis() {
        // 0.31 removes decorative emoji from the interface. Keep the persisted
        // coverSymbol field for backwards compatibility, but normalize it to an
        // SF Symbol so older workspaces never surface colorful emoji again.
        let legacy: Set<String> = ["\u{1F399}\u{FE0F}", "\u{1F3C3}", "\u{1F3B5}", "\u{1F4BB}", "\u{1F3DB}\u{FE0F}", "\u{2728}", "\u{1F3AC}", "\u{1F3A5}", "\u{1F39F}\u{FE0F}", "\u{1F4F1}", "\u{1F4F8}"]
        for index in projects.indices {
            if projects[index].kind == nil { projects[index].kind = .commercial }
            if legacy.contains(projects[index].coverSymbol) || projects[index].coverSymbol.isEmpty {
                projects[index].coverSymbol = projects[index].kind?.icon ?? "film"
            }
            // 0.33 stops auto-branding project covers. Older projects created with
            // the automatic first bundled banner fall back to their project color.
            if projects[index].bannerPath == nil,
               let assetName = projects[index].bannerAssetName,
               StudioBannerDefaults.bundled.contains(assetName) {
                // Bundled project artwork was part of the early demo UI. 0.34
                // keeps project covers intentionally neutral unless the user
                // chooses an actual image.
                projects[index].bannerAssetName = nil
            }
        }
        for index in spaces.indices {
            if spaces[index].emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                spaces[index].emoji = "square.stack.3d.up"
            }
        }
    }

    private func defaultSpaces(for projects: [StudioProject]) -> [StudioSpace] {
        [
            StudioSpace(title: "Workspace", subtitle: "Active productions and client work", emoji: "square.stack.3d.up", colorHex: "7D9990", bannerPath: nil, projectIDs: projects.map(\.id), notes: "Your active MODO workspace."),
            StudioSpace(title: "Personal", subtitle: "Films, experiments and ideas", emoji: "leaf", colorHex: "A87E6B", bannerPath: nil, projectIDs: [], notes: "Personal work in progress."),
            StudioSpace(title: "Archive", subtitle: "Delivered work worth keeping close", emoji: "archivebox", colorHex: "8F88A3", bannerPath: nil, projectIDs: projects.filter { $0.status == .delivered }.map(\.id), notes: "Completed productions.")
        ]
    }

    private func seedPreviewData() {
        let calendar = Calendar.current
        let day: (Int) -> Date = { calendar.date(byAdding: .day, value: $0, to: .now) ?? .now }

        let crew = [
            CrewMember(name: "Alex Morgan", role: "Director / DOP", email: "alex@example.com", initials: "AM", phone: "+32 470 00 00 00"),
            CrewMember(name: "Mila De Smet", role: "Producer", email: "mila@example.com", initials: "MD"),
            CrewMember(name: "Noah Janssens", role: "Sound", email: "noah@example.com", initials: "NJ")
        ]
        let kit = [
            KitItem(name: "Cinema camera", category: "Camera", packed: true, quantity: 1, serialNumber: "DEMO-CAM-01"),
            KitItem(name: "24–70mm lens", category: "Lens", packed: true, quantity: 1),
            KitItem(name: "Wireless audio kit", category: "Audio", packed: false, quantity: 2),
            KitItem(name: "Gimbal", category: "Support", packed: false, quantity: 1)
        ]
        let sampleShots = [
            Shot(number: 1, title: "Opening exterior", description: "Establish the location and atmosphere.", shotSize: "Wide", movement: "Push in", lens: "24mm", frameRate: "25 fps", duration: "5 sec", completed: true),
            Shot(number: 2, title: "Hands at work", description: "Detailed process and texture inserts.", shotSize: "Close-up", movement: "Handheld", lens: "70mm", frameRate: "50 fps", duration: "4 sec", completed: false),
            Shot(number: 3, title: "Hero portrait", description: "A clean portrait for the final beat.", shotSize: "Medium", movement: "Static", lens: "50mm", frameRate: "25 fps", duration: "6 sec", completed: false)
        ]

        let project = StudioProject(
            title: "MODO Test Project", client: "Example client", description: "A complete example production. Explore every tab, replace the demo content, or delete this project when you are ready.",
            status: .preproduction, startDate: day(0), dueDate: day(12), location: "Gent",
            colorHex: "74736F", coverSymbol: "film", kind: .commercial, bannerPath: nil, editingSoftware: "DaVinci Resolve", aspectRatio: "16:9",
            resolution: "4K UHD", frameRate: "25 fps", brief: "Create a short visual story with a clear beginning, middle and end.",
            script: "OPEN on the location. Move into details and process. Finish on a simple hero image and client mark.",
            deliverable: "1 × 45 sec master · 3 × social cutdowns", favorite: true, createdAt: day(0),
            shots: sampleShots, crew: crew, kit: kit,
            storyboard: sampleShots.map { StoryboardCard(shotNumber: $0.number, title: $0.title, notes: $0.description) }, timeEntries: [],
            bannerAssetName: nil, frameIOURL: nil, clientShareURL: nil
        )
        projects = [project]
        tasks = [
            StudioTask(title: "Confirm location", dueDate: day(2), projectID: project.id, priority: 2),
            StudioTask(title: "Send call sheet", dueDate: day(4), projectID: project.id, priority: 2),
            StudioTask(title: "Prepare camera package", dueDate: day(5), projectID: project.id),
            StudioTask(title: "Create first edit", dueDate: day(9), projectID: project.id)
        ]
        events = [
            StudioEvent(title: "Test project shoot", date: day(6), endDate: day(6).addingTimeInterval(4 * 3600), projectID: project.id, location: "Gent", colorHex: "74736F")
        ]
        spaces = defaultSpaces(for: projects)
        places = [
            StudioPlace(name: "Sample location", address: "Gent, Belgium", notes: "This is a demo place. Add photos, notes and link it to the test project.", latitude: 51.0543, longitude: 3.7174, photoPaths: [], projectIDs: [project.id])
        ]

        let customer = ModoOrganization(name: "Example client", email: "hello@example.com", city: "Gent", countryCode: "BE", notes: "Sample customer for the inquiry-to-paid workflow.")
        let opportunity = ModoOpportunity(customerID: customer.id, title: "Campaign video", stage: .proposal, expectedValue: 2400, currency: settings.currency, nextAction: "Follow up on proposal", nextActionDate: day(1), notes: "Use this sample to test the business workflow.")
        let quote = ModoQuote(quoteNumber: "Q-2026-0001", customerID: customer.id, opportunityID: opportunity.id, status: .sent, currency: settings.currency, lines: [ModoQuoteLine(name: "Production package", description: "Pre-production, shoot and edit", quantity: 1, unitPrice: 2400, taxRate: 21)])
        business = ModoBusinessState(
            organizations: [customer],
            people: [],
            opportunities: [opportunity],
            quotes: [quote],
            payments: [],
            activities: [ModoActivityEntry(kind: .created, summary: "Sample customer and proposal created", recordType: "customer", recordID: customer.id)]
        )
    }

}

@MainActor
final class FramoCalendarBridge: ObservableObject {
    @Published private(set) var hasAccess = false
    private let store = EKEventStore()
    private let calendarTitle = "MODO"

    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = await withCheckedContinuation { continuation in
                    store.requestAccess(to: .event) { success, _ in continuation.resume(returning: success) }
                }
            }
            hasAccess = granted
            return granted
        } catch {
            hasAccess = false
            return false
        }
    }

    func upsert(events: [StudioEvent]) throws -> [UUID: String] {
        guard hasAccess else { return [:] }
        let calendar = try framoCalendar()
        var savedEvents: [(UUID, EKEvent)] = []

        for item in events {
            let event: EKEvent
            if let identifier = item.appleEventIdentifier,
               let existing = store.event(withIdentifier: identifier) {
                event = existing
            } else {
                event = EKEvent(eventStore: store)
            }
            event.calendar = calendar
            event.title = item.title
            event.startDate = item.date
            event.endDate = max(item.endDate, item.date.addingTimeInterval(1800))
            event.location = item.location.isEmpty ? nil : item.location
            event.notes = "Created by MODO"
            try store.save(event, span: .thisEvent, commit: false)
            savedEvents.append((item.id, event))
        }
        try store.commit()

        var identifiers: [UUID: String] = [:]
        for (id, event) in savedEvents {
            if let identifier = event.eventIdentifier {
                identifiers[id] = identifier
            }
        }
        return identifiers
    }

    func events(from start: Date, to end: Date) -> [StudioEvent] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { item in
            StudioEvent(
                title: item.title ?? "Calendar event",
                date: item.startDate,
                endDate: item.endDate,
                projectID: nil,
                location: item.location ?? "Apple Calendar",
                colorHex: "81817E",
                appleEventIdentifier: item.eventIdentifier
            )
        }
    }

    private func framoCalendar() throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) { return existing }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle
        calendar.source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local })
        guard calendar.source != nil else { throw NSError(domain: "MODO.Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No writable Calendar source is available."]) }
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }
}

final class FramoV5LocalTransferService: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isActive = false
    @Published private(set) var availablePeers: [MCPeerID] = []
    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var status = "Off"
    @Published private(set) var lastReceivedURL: URL?
    @Published private(set) var lastTransferName: String?
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var isTransferring = false
    @Published private(set) var transferDirection = ""
    @Published private(set) var transferTransport = ""

    var peers: [MCPeerID] {
        let connected = connectedPeers
        return connected + availablePeers.filter { !connected.contains($0) }
    }

    private let serviceType = "framo-xfer"
    private let peerID: MCPeerID
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["app": "MODO"], serviceType: serviceType)
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
    private var transferProgressObservation: NSKeyValueObservation?

    override init() {
        let deviceName = Host.current().localizedName ?? "Mac"
        peerID = MCPeerID(displayName: "MODO · \(deviceName)")
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Looking for nearby MODO devices"
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        guard isActive else { return }
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        availablePeers.removeAll()
        connectedPeers.removeAll()
        isActive = false
        status = "Off"
    }

    func connect(to peer: MCPeerID) {
        guard !session.connectedPeers.contains(peer) else { return }
        status = "Connecting to \(peer.displayName)…"
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func sendFile(url: URL, to peer: MCPeerID, completion: (() -> Void)? = nil) {
        guard session.connectedPeers.contains(peer) else {
            status = "Connect to \(peer.displayName) first"
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let maxTransferBytes: Int64 = 100 * 1024 * 1024 * 1024
        guard size == 0 || size <= maxTransferBytes else {
            status = "MODO Direct supports files up to 100 GB"
            return
        }
        status = "Sending \(url.lastPathComponent)…"
        lastTransferName = url.lastPathComponent
        transferDirection = "Sending to \(peer.displayName)"
        transferTransport = "Peer-to-peer"
        transferProgress = 0
        isTransferring = true
        let progress = session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peer) { [weak self] error in
            DispatchQueue.main.async {
                self?.transferProgressObservation = nil
                self?.isTransferring = false
                self?.transferProgress = error == nil ? 1 : 0
                if let error {
                    self?.status = "Transfer failed: \(error.localizedDescription)"
                } else {
                    self?.lastTransferName = url.lastPathComponent
                    self?.status = "Sent to \(peer.displayName)"
                }
                completion?()
            }
        }
        if let progress {
            transferProgressObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                DispatchQueue.main.async { self?.transferProgress = progress.fractionCompleted }
            }
        }
    }

    @MainActor
    func chooseAndSendFile(to peer: MCPeerID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { sendFile(url: url, to: peer) }
    }

    @MainActor
    func chooseAndCopyViaCableOrDrive() {
        let sourcePanel = NSOpenPanel()
        sourcePanel.canChooseFiles = true
        sourcePanel.canChooseDirectories = false
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.prompt = "Choose file"
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }

        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let maxTransferBytes: Int64 = 100 * 1024 * 1024 * 1024
        guard size == 0 || size <= maxTransferBytes else {
            status = "Cable/drive transfer supports files up to 100 GB"
            return
        }

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.allowsMultipleSelection = false
        destinationPanel.prompt = "Copy here"
        guard destinationPanel.runModal() == .OK, let destinationFolder = destinationPanel.url else { return }

        let sourceAccess = source.startAccessingSecurityScopedResource()
        let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
        var destination = destinationFolder.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            destination = destinationFolder.appendingPathComponent(base + "-copy" + (ext.isEmpty ? "" : "." + ext))
        }

        transferDirection = "Copying to " + destinationFolder.lastPathComponent
        transferTransport = "Cable / drive"
        transferProgress = 0
        isTransferring = true
        status = "Copying " + source.lastPathComponent + "…"
        lastTransferName = source.lastPathComponent

        let transferService = self
        Task.detached(priority: .utility) {
            defer {
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
            }
            do {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let input = try FileHandle(forReadingFrom: source)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? input.close(); try? output.close() }
                let total = max(Int64(1), size)
                var copied: Int64 = 0

                while true {
                    guard let data = try input.read(upToCount: 8 * 1024 * 1024), !data.isEmpty else { break }
                    try output.write(contentsOf: data)
                    copied += Int64(data.count)
                    let fraction = min(1, Double(copied) / Double(total))
                    await MainActor.run {
                        transferService.transferProgress = fraction
                    }
                }

                await MainActor.run {
                    transferService.transferProgress = 1
                    transferService.isTransferring = false
                    transferService.lastReceivedURL = destination
                    transferService.status = "Copied to " + destinationFolder.lastPathComponent
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                let message = error.localizedDescription
                await MainActor.run {
                    transferService.transferProgress = 0
                    transferService.isTransferring = false
                    transferService.status = "Copy failed: " + message
                }
            }
        }
    }

    private func refreshConnectedPeers() {
        connectedPeers = session.connectedPeers.sorted { $0.displayName < $1.displayName }
        status = connectedPeers.isEmpty ? "Looking for nearby MODO devices" : "Connected to \(connectedPeers.count) device\(connectedPeers.count == 1 ? "" : "s")"
    }
}

extension FramoV5LocalTransferService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in self?.status = "Couldn’t start sharing: \(error.localizedDescription)" }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(isActive, isActive ? session : nil)
    }
}

extension FramoV5LocalTransferService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in self?.status = "Couldn’t browse nearby devices: \(error.localizedDescription)" }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, peerID != self.peerID, !self.availablePeers.contains(peerID) else { return }
            self.availablePeers.append(peerID)
            self.availablePeers.sort { $0.displayName < $1.displayName }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in self?.availablePeers.removeAll { $0 == peerID } }
    }
}

extension FramoV5LocalTransferService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in self?.refreshConnectedPeers() }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) { }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.status = "Receiving \(resourceName)…"
            self.lastTransferName = resourceName
            self.transferDirection = "Receiving from \(peerID.displayName)"
            self.transferTransport = "Peer-to-peer"
            self.transferProgress = 0
            self.isTransferring = true
            self.transferProgressObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                DispatchQueue.main.async { self?.transferProgress = progress.fractionCompleted }
            }
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard error == nil, let localURL else {
            DispatchQueue.main.async { [weak self] in
                self?.transferProgressObservation = nil
                self?.isTransferring = false
                self?.transferProgress = 0
                self?.status = "Receive failed: \(error?.localizedDescription ?? "Unknown error")"
            }
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MODO Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(resourceName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            destination = folder.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970))" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        do {
            try FileManager.default.copyItem(at: localURL, to: destination)
            DispatchQueue.main.async { [weak self] in
                self?.transferProgressObservation = nil
                self?.isTransferring = false
                self?.transferProgress = 1
                self?.lastReceivedURL = destination
                self?.lastTransferName = resourceName
                self?.status = "Received from \(peerID.displayName)"
            }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.status = "Couldn’t save received file: \(error.localizedDescription)" }
        }
    }

    #if os(iOS)
    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) { certificateHandler(true) }
    #endif
}

// MARK: - Self-hosted MODO access

struct FramoV5HostedFile: Hashable {
    let id: UUID
    let projectID: UUID
    let projectTitle: String
    let name: String
    let byteSize: Int64
    let volumeName: String
    let bookmarkData: Data
    let fallbackPath: String
}

enum FramoV5RemoteItemKind: String, Codable, Hashable {
    case workspace
    case linkedFile
}

struct FramoV5RemoteItem: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: FramoV5RemoteItemKind
    let name: String
    let byteSize: Int64
    let projectTitle: String?
    let volumeName: String?
    let path: String

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
}

struct FramoV5RemoteManifest: Codable, Hashable {
    let workspaceName: String
    let generatedAt: Date
    let items: [FramoV5RemoteItem]
}

final class FramoV5HostService: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Off"
    @Published private(set) var activePort: Int?
    @Published private(set) var connectionCount = 0

    private let queue = DispatchQueue(label: "framo.host.server", qos: .utility)
    private var listener: NWListener?
    private var token = ""
    private var workspaceURL: URL?
    private var workspaceName = "MODO"
    private var shares: [FramoV5HostedFile] = []
    private var shareWorkspace = true
    private var shareLinkedFiles = true

    func start(port: Int, token: String, workspaceURL: URL, workspaceName: String, shares: [FramoV5HostedFile], shareWorkspace: Bool, shareLinkedFiles: Bool) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            publish(status: "Invalid host port", running: false, port: nil)
            return
        }
        self.token = token
        self.workspaceURL = workspaceURL
        self.workspaceName = workspaceName
        self.shares = shares
        self.shareWorkspace = shareWorkspace
        self.shareLinkedFiles = shareLinkedFiles

        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = NWListener.Service(name: "MODO Host", type: "_framo-host._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let actual = listener.port.map { Int($0.rawValue) }
                    self?.publish(status: "MODO Host is online", running: true, port: actual)
                case .failed(let error):
                    self?.publish(status: "Host failed: \(error.localizedDescription)", running: false, port: nil)
                case .cancelled:
                    self?.publish(status: "Off", running: false, port: nil)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            listener.start(queue: queue)
            publish(status: "Starting MODO Host…", running: false, port: port)
        } catch {
            publish(status: "Host failed: \(error.localizedDescription)", running: false, port: nil)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        publish(status: "Off", running: false, port: nil)
    }

    func updateShares(_ shares: [FramoV5HostedFile]) {
        queue.async { [weak self] in self?.shares = shares }
    }

    private func accept(_ connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in self?.connectionCount += 1 }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state { connection?.cancel() }
            if case .cancelled = state { DispatchQueue.main.async { self?.connectionCount = max(0, (self?.connectionCount ?? 1) - 1) } }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil || complete {
                self.route(requestData: next, connection: connection)
            } else if error == nil, next.count < 128 * 1024 {
                self.receiveRequest(on: connection, buffer: next)
            } else {
                connection.cancel()
            }
        }
    }

    private func route(requestData: Data, connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8) else { sendError(400, "Bad request", connection); return }
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { sendError(400, "Bad request", connection); return }
        let pieces = first.split(separator: " ")
        guard pieces.count >= 2, pieces[0] == "GET" else { sendError(405, "GET only", connection); return }
        let path = String(pieces[1]).removingPercentEncoding ?? String(pieces[1])
        let auth = lines.first(where: { $0.lowercased().hasPrefix("authorization:") }) ?? ""
        let suppliedToken = auth.replacingOccurrences(of: "Authorization:", with: "", options: [.caseInsensitive]).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive]).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, suppliedToken == token else { sendError(401, "Unauthorized", connection); return }

        if path == "/manifest" {
            sendManifest(connection)
        } else if path == "/workspace" {
            guard shareWorkspace, let workspaceURL else { sendError(404, "Workspace sharing is off", connection); return }
            sendFile(workspaceURL, downloadName: "\(workspaceName)-Workspace.framo", requestLines: lines, connection: connection, scoped: false)
        } else if path.hasPrefix("/file/") {
            guard shareLinkedFiles, let id = UUID(uuidString: String(path.dropFirst("/file/".count))), let share = shares.first(where: { $0.id == id }) else {
                sendError(404, "File not found", connection); return
            }
            guard let resolved = resolve(share) else { sendError(410, "Linked drive is unavailable", connection); return }
            let scoped = resolved.startAccessingSecurityScopedResource()
            sendFile(resolved, downloadName: share.name, requestLines: lines, connection: connection, scoped: scoped)
        } else {
            sendError(404, "Not found", connection)
        }
    }

    private func sendManifest(_ connection: NWConnection) {
        var items: [FramoV5RemoteItem] = []
        if shareWorkspace, let workspaceURL {
            let size = ((try? FileManager.default.attributesOfItem(atPath: workspaceURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            items.append(FramoV5RemoteItem(id: UUID(), kind: .workspace, name: "\(workspaceName)-Workspace.framo", byteSize: size, projectTitle: nil, volumeName: nil, path: "/workspace"))
        }
        if shareLinkedFiles {
            items += shares.map {
                FramoV5RemoteItem(id: $0.id, kind: .linkedFile, name: $0.name, byteSize: $0.byteSize, projectTitle: $0.projectTitle, volumeName: $0.volumeName, path: "/file/\($0.id.uuidString)")
            }
        }
        let manifest = FramoV5RemoteManifest(workspaceName: workspaceName, generatedAt: .now, items: items)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { sendError(500, "Could not build manifest", connection); return }
        sendResponse(status: "200 OK", headers: ["Content-Type": "application/json", "Content-Length": "\(data.count)"], body: data, connection: connection)
    }

    private func sendFile(_ url: URL, downloadName: String, requestLines: [String], connection: NWConnection, scoped: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let rangeHeader = requestLines.first(where: { $0.lowercased().hasPrefix("range:") })
        let range = parseRange(rangeHeader, total: total)
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? max(0, total - 1)
        let length = max(0, end - start + 1)
        let status = range == nil ? "200 OK" : "206 Partial Content"
        var headers = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(length)",
            "Content-Disposition": "attachment; filename=\"\(downloadName.replacingOccurrences(of: "\"", with: ""))\"",
            "Accept-Ranges": "bytes"
        ]
        if range != nil { headers["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        let head = responseHeader(status: status, headers: headers)
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard error == nil else { if scoped { url.stopAccessingSecurityScopedResource() }; connection.cancel(); return }
            self?.streamFile(url: url, offset: start, remaining: length, connection: connection) {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        })
    }

    private func streamFile(url: URL, offset: Int64, remaining: Int64, connection: NWConnection, completion: @escaping () -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { completion(); connection.cancel(); return }
        do { try handle.seek(toOffset: UInt64(max(0, offset))) } catch { try? handle.close(); completion(); connection.cancel(); return }
        streamChunk(handle: handle, remaining: remaining, connection: connection, completion: completion)
    }

    private func streamChunk(handle: FileHandle, remaining: Int64, connection: NWConnection, completion: @escaping () -> Void) {
        guard remaining > 0 else {
            try? handle.close(); completion(); connection.cancel(); return
        }
        let count = Int(min(1_048_576, remaining))
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else {
            try? handle.close(); completion(); connection.cancel(); return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); completion(); connection.cancel(); return }
            self?.streamChunk(handle: handle, remaining: remaining - Int64(data.count), connection: connection, completion: completion)
        })
    }

    private func parseRange(_ header: String?, total: Int64) -> ClosedRange<Int64>? {
        guard let header, let raw = header.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), raw.hasPrefix("bytes=") else { return nil }
        let parts = raw.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let start = Int64(first), start >= 0, start < total else { return nil }
        let end = parts.count > 1 && !parts[1].isEmpty ? min(Int64(parts[1]) ?? total - 1, total - 1) : total - 1
        return start...max(start, end)
    }

    private func resolve(_ share: FramoV5HostedFile) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: share.bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path) { return url }
        let fallback = URL(fileURLWithPath: share.fallbackPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func sendError(_ code: Int, _ message: String, _ connection: NWConnection) {
        let body = Data(message.utf8)
        sendResponse(status: "\(code) \(message)", headers: ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "\(body.count)"], body: body, connection: connection)
    }

    private func sendResponse(status: String, headers: [String: String], body: Data, connection: NWConnection) {
        var data = responseHeader(status: status, headers: headers)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func responseHeader(status: String, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    private func publish(status: String, running: Bool, port: Int?) {
        DispatchQueue.main.async { [weak self] in self?.status = status; self?.isRunning = running; self?.activePort = port }
    }
}

final class FramoTorConnectService: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = "Off"
    @Published private(set) var isRunning = false
    @Published private(set) var bootstrapProgress: Double = 0
    @Published private(set) var onionAddress: String?
    @Published private(set) var socksPort: Int = 19050
    @Published private(set) var executableName: String?
    @Published private(set) var recentLog = ""

    private let queue = DispatchQueue(label: "framo.connect.tor", qos: .utility)
    private var process: Process?
    private var pipe: Pipe?
    private var hostnameTimer: DispatchSourceTimer?
    private var scopedExecutableURL: URL?
    private var isAccessingScopedExecutable = false

    init() {
        onionAddress = Self.savedOnionAddress()
    }

    func markTorMissing() {
        publish(status: "Remote needs Tor before it can start", running: false, progress: 0)
    }

    func markSetupIssue(_ message: String) {
        publish(status: message, running: false, progress: 0)
    }

    func start(executableURL: URL, targetPort: Int, socksPort: Int) {
        stop(clearStatus: false)
        self.socksPort = socksPort
        self.executableName = executableURL.lastPathComponent

        let root = Self.connectRootURL()
        let dataDirectory = root.appendingPathComponent("Data", isDirectory: true)
        let hiddenDirectory = root.appendingPathComponent("OnionService", isDirectory: true)
        let configURL = root.appendingPathComponent("torrc")

        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hiddenDirectory.path)

            let torrc = """
            DataDirectory \(Self.torQuotedPath(dataDirectory.path))
            SocksPort 127.0.0.1:\(socksPort)
            HiddenServiceDir \(Self.torQuotedPath(hiddenDirectory.path))
            HiddenServiceVersion 3
            HiddenServicePort 80 127.0.0.1:\(targetPort)
            Log notice stdout
            """
            try torrc.write(to: configURL, atomically: true, encoding: .utf8)

            let scoped = executableURL.startAccessingSecurityScopedResource()
            scopedExecutableURL = executableURL
            isAccessingScopedExecutable = scoped

            let pipe = Pipe()
            self.pipe = pipe
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["-f", configURL.path]
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.process === process {
                        self.isRunning = false
                        if process.terminationStatus != 0 && !self.status.hasPrefix("Stopped") {
                            self.status = "Tor stopped (exit \(process.terminationStatus))"
                        } else if self.status != "Off" {
                            self.status = "Off"
                        }
                    }
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                self?.handleTorOutput(text)
            }

            self.process = process
            try process.run()
            publish(status: "Starting Tor…", running: true, progress: 0)
            startHostnamePolling(directory: hiddenDirectory)
        } catch {
            stop(clearStatus: false)
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 13 {
                publish(status: "macOS blocked Tor (permission denied). In this development build, check App Sandbox or use a Tor runtime bundled inside MODO.", running: false, progress: 0)
            } else {
                publish(status: "Couldn’t start Tor: \(error.localizedDescription)", running: false, progress: 0)
            }
        }
    }

    func stop() {
        stop(clearStatus: true)
    }

    private func stop(clearStatus: Bool) {
        hostnameTimer?.cancel()
        hostnameTimer = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        if isAccessingScopedExecutable, let scopedExecutableURL {
            scopedExecutableURL.stopAccessingSecurityScopedResource()
        }
        scopedExecutableURL = nil
        isAccessingScopedExecutable = false
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            self?.bootstrapProgress = 0
            if clearStatus { self?.status = "Off" }
        }
    }

    private func handleTorOutput(_ text: String) {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return }
        let progress = Self.bootstrapPercent(in: text)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentLog = String((self.recentLog + "\n" + compact).suffix(4000))
            if let progress {
                self.bootstrapProgress = Double(progress) / 100.0
                self.status = progress >= 100 ? "Tor ready · publishing Onion Service" : "Bootstrapping Tor · \(progress)%"
            }
        }
    }

    private func startHostnamePolling(directory: URL) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let hostnameURL = directory.appendingPathComponent("hostname")
            guard let value = try? String(contentsOf: hostnameURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  value.hasSuffix(".onion") else { return }
            DispatchQueue.main.async {
                self.onionAddress = value
                if self.bootstrapProgress >= 0.99 {
                    self.status = "Online over Tor"
                } else {
                    self.status = "Onion address ready · Tor is still bootstrapping"
                }
            }
        }
        hostnameTimer = timer
        timer.resume()
    }

    private func publish(status: String, running: Bool, progress: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.status = status
            self?.isRunning = running
            self?.bootstrapProgress = progress
        }
    }

    private static func bootstrapPercent(in text: String) -> Int? {
        guard let range = text.range(of: #"Bootstrapped\s+(\d+)%"#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        let digits = match.filter(\.isNumber)
        return Int(digits)
    }

    private static func torQuotedPath(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func connectRootURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Bywarre Studio", isDirectory: true)
            .appendingPathComponent("FramoConnect", isDirectory: true)
            .appendingPathComponent("Tor", isDirectory: true)
    }

    private static func savedOnionAddress() -> String? {
        let url = connectRootURL().appendingPathComponent("OnionService/hostname")
        guard let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasSuffix(".onion") else { return nil }
        return value
    }
}

final class FramoV5RemoteAccessService: ObservableObject, @unchecked Sendable {
    @Published private(set) var manifest: FramoV5RemoteManifest?
    @Published private(set) var status = "Not connected"
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var transportLabel = "Direct"

    private enum Route {
        case direct(host: String, port: UInt16)
        case tor(onionHost: String, socksPort: UInt16, targetPort: UInt16)

        var hostHeader: String {
            switch self {
            case .direct(let host, _): host
            case .tor(let onionHost, _, _): onionHost
            }
        }
    }

    private let queue = DispatchQueue(label: "framo.remote.client", qos: .utility)
    private var route: Route = .direct(host: "", port: 45888)
    private var token = ""

    func connect(host: String, port: Int, token: String) {
        self.route = .direct(host: host, port: UInt16(clamping: port))
        self.token = token
        self.transportLabel = "Direct"
        connectManifest(statusText: "Connecting directly…")
    }

    func connectViaTor(onionHost: String, token: String, socksPort: Int) {
        self.route = .tor(onionHost: onionHost, socksPort: UInt16(clamping: socksPort), targetPort: 80)
        self.token = token
        self.transportLabel = "Tor Onion Service"
        connectManifest(statusText: "Connecting over Tor…")
    }

    func disconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.manifest = nil
            self?.status = "Not connected"
        }
    }

    private func connectManifest(statusText: String) {
        publishStatus(statusText)
        request(path: "/manifest") { [weak self] result in
            switch result {
            case .success(let data):
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                do {
                    let manifest = try decoder.decode(FramoV5RemoteManifest.self, from: data)
                    DispatchQueue.main.async {
                        self?.manifest = manifest
                        self?.status = "Connected to \(manifest.workspaceName)"
                    }
                } catch {
                    self?.publishStatus("Couldn’t read remote workspace: \(error.localizedDescription)")
                }
            case .failure(let error):
                self?.publishStatus("Remote Mac unavailable: \(error.localizedDescription)")
            }
        }
    }

    func download(item: FramoV5RemoteItem, to destination: URL, completion: (() -> Void)? = nil) {
        isDownloading = true
        downloadProgress = 0
        status = "Downloading \(item.name)…"
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            publishStatus("Couldn’t create destination file")
            completion?()
            return
        }

        openConnection { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                try? handle.close()
                self.finishDownload(status: "Download failed: \(error.localizedDescription)")
                completion?()
            case .success(let connection):
                self.sendRequest(path: item.path, connection: connection) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        try? handle.close()
                        connection.cancel()
                        self.finishDownload(status: "Download failed: \(error.localizedDescription)")
                        completion?()
                        return
                    }
                    self.receiveDownload(connection: connection, handle: handle, expected: item.byteSize, received: 0, headerBuffer: Data(), headersParsed: false, fileName: item.name, completion: completion)
                }
            }
        }
    }

    private func receiveDownload(connection: NWConnection, handle: FileHandle, expected: Int64, received: Int64, headerBuffer: Data, headersParsed: Bool, fileName: String, completion: (() -> Void)?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                try? handle.close(); connection.cancel(); self.finishDownload(status: "Download failed: \(error.localizedDescription)"); completion?(); return
            }
            var bodyData = data ?? Data()
            var parsed = headersParsed
            var buffer = headerBuffer
            var totalReceived = received

            if !parsed {
                buffer.append(bodyData)
                guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { try? handle.close(); connection.cancel(); self.finishDownload(status: "Invalid remote response"); completion?() }
                    else { self.receiveDownload(connection: connection, handle: handle, expected: expected, received: received, headerBuffer: buffer, headersParsed: false, fileName: fileName, completion: completion) }
                    return
                }
                let headerData = buffer[..<split.lowerBound]
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                guard headerText.contains(" 200 ") || headerText.contains(" 206 ") else {
                    try? handle.close(); connection.cancel(); self.finishDownload(status: "Remote Mac refused the download"); completion?(); return
                }
                bodyData = Data(buffer[split.upperBound...])
                parsed = true
                buffer.removeAll(keepingCapacity: false)
            }

            if !bodyData.isEmpty {
                do { try handle.write(contentsOf: bodyData); totalReceived += Int64(bodyData.count) }
                catch { try? handle.close(); connection.cancel(); self.finishDownload(status: "Couldn’t write download: \(error.localizedDescription)"); completion?(); return }
                let denominator = max(expected, 1)
                DispatchQueue.main.async { self.downloadProgress = min(1, Double(totalReceived) / Double(denominator)) }
            }

            if complete {
                try? handle.close(); connection.cancel(); self.finishDownload(status: "Downloaded \(fileName)"); completion?()
            } else {
                self.receiveDownload(connection: connection, handle: handle, expected: expected, received: totalReceived, headerBuffer: buffer, headersParsed: parsed, fileName: fileName, completion: completion)
            }
        }
    }

    private func request(path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        openConnection { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let connection):
                var buffer = Data()
                self.sendRequest(path: path, connection: connection) { error in
                    if let error { connection.cancel(); completion(.failure(error)); return }
                    func receiveMore() {
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                            if let data { buffer.append(data) }
                            if let error { completion(.failure(error)); connection.cancel(); return }
                            if complete {
                                connection.cancel()
                                guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { completion(.failure(RemoteError.invalidResponse)); return }
                                let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) ?? ""
                                guard header.contains(" 200 ") else { completion(.failure(RemoteError.unauthorizedOrUnavailable)); return }
                                completion(.success(Data(buffer[split.upperBound...])))
                            } else { receiveMore() }
                        }
                    }
                    receiveMore()
                }
            }
        }
    }

    private func openConnection(completion: @escaping (Result<NWConnection, Error>) -> Void) {
        let endpointHost: NWEndpoint.Host
        let endpointPort: NWEndpoint.Port
        switch route {
        case .direct(let host, let port):
            endpointHost = NWEndpoint.Host(host)
            endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 45888)!
        case .tor(_, let socksPort, _):
            endpointHost = "127.0.0.1"
            endpointPort = NWEndpoint.Port(rawValue: socksPort) ?? NWEndpoint.Port(rawValue: 19050)!
        }

        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        var resolved = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !resolved else { return }
                resolved = true
                switch self.route {
                case .direct:
                    completion(.success(connection))
                case .tor(let onionHost, _, let targetPort):
                    self.performSOCKS5Handshake(connection: connection, host: onionHost, port: targetPort) { result in
                        switch result {
                        case .success: completion(.success(connection))
                        case .failure(let error): connection.cancel(); completion(.failure(error))
                        }
                    }
                }
            case .failed(let error):
                guard !resolved else { return }
                resolved = true
                completion(.failure(error))
            case .cancelled:
                if !resolved {
                    resolved = true
                    completion(.failure(RemoteError.connectionCancelled))
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func performSOCKS5Handshake(connection: NWConnection, host: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        connection.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            self.receiveExact(connection: connection, count: 2) { greeting in
                switch greeting {
                case .failure(let error): completion(.failure(error))
                case .success(let data):
                    guard data.count == 2, data[data.startIndex] == 0x05, data[data.index(after: data.startIndex)] == 0x00 else {
                        completion(.failure(RemoteError.socksFailure("Tor SOCKS authentication failed")))
                        return
                    }
                    guard let hostData = host.data(using: .utf8), hostData.count <= 255 else {
                        completion(.failure(RemoteError.socksFailure("Invalid onion address")))
                        return
                    }
                    var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostData.count)])
                    request.append(hostData)
                    request.append(UInt8((port >> 8) & 0xff))
                    request.append(UInt8(port & 0xff))
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { completion(.failure(error)); return }
                        self.receiveSOCKSReply(connection: connection, completion: completion)
                    })
                }
            }
        })
    }

    private func receiveSOCKSReply(connection: NWConnection, completion: @escaping (Result<Void, Error>) -> Void) {
        receiveExact(connection: connection, count: 4) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let header):
                guard header.count == 4 else { completion(.failure(RemoteError.invalidResponse)); return }
                let bytes = [UInt8](header)
                guard bytes[0] == 0x05, bytes[1] == 0x00 else {
                    completion(.failure(RemoteError.socksFailure("Tor could not reach that Onion Service (SOCKS code \(bytes[1]))")))
                    return
                }
                switch bytes[3] {
                case 0x01:
                    self.receiveExact(connection: connection, count: 6) { result in completion(result.map { _ in () }) }
                case 0x04:
                    self.receiveExact(connection: connection, count: 18) { result in completion(result.map { _ in () }) }
                case 0x03:
                    self.receiveExact(connection: connection, count: 1) { lengthResult in
                        switch lengthResult {
                        case .failure(let error): completion(.failure(error))
                        case .success(let lengthData):
                            guard let length = lengthData.first else { completion(.failure(RemoteError.invalidResponse)); return }
                            self.receiveExact(connection: connection, count: Int(length) + 2) { result in completion(result.map { _ in () }) }
                        }
                    }
                default:
                    completion(.failure(RemoteError.invalidResponse))
                }
            }
        }
    }

    private func receiveExact(connection: NWConnection, count: Int, accumulated: Data = Data(), completion: @escaping (Result<Data, Error>) -> Void) {
        if accumulated.count >= count { completion(.success(accumulated)); return }
        let remaining = count - accumulated.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            var next = accumulated
            if let data { next.append(data) }
            if next.count >= count { completion(.success(next)); return }
            if complete { completion(.failure(RemoteError.invalidResponse)); return }
            self.receiveExact(connection: connection, count: count, accumulated: next, completion: completion)
        }
    }

    private func sendRequest(path: String, connection: NWConnection, completion: @escaping (Error?) -> Void) {
        let request = "GET \(path) HTTP/1.1\r\nHost: \(route.hostHeader)\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in completion(error) })
    }

    private func finishDownload(status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isDownloading = false
            self?.downloadProgress = 1
            self?.status = status
        }
    }

    private func publishStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.status = value }
    }

    private enum RemoteError: LocalizedError {
        case invalidResponse
        case unauthorizedOrUnavailable
        case connectionCancelled
        case socksFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The remote MODO host returned an invalid response."
            case .unauthorizedOrUnavailable: "The remote Mac rejected the request. Check the invite or access token."
            case .connectionCancelled: "The connection was cancelled."
            case .socksFailure(let message): message
            }
        }
    }
}


// MARK: - MODO plugin runtime

private final class FramoWebTorrentSeedState: @unchecked Sendable {
    let lock = NSLock()
    var buffer = ""
    var didPublish = false
}

@MainActor
final class FramoV5PluginManager: ObservableObject {
    @Published private(set) var externalPlugins: [FramoPluginManifest] = []
    @Published private(set) var customRuntimeRevision = 0

    private var packageRoots: [String: URL] = [:]
    private var activeWebTorrentProcesses: [UUID: Process] = [:]
    private var scopedRuntimeURLs: [String: URL] = [:]
    private let runtimeBookmarksKey = "framo.plugin.runtime-bookmarks"

    var catalog: [FramoPluginManifest] {
        var items = Self.builtInCatalog.filter { !$0.actions.isEmpty }
        for plugin in externalPlugins where !items.contains(where: { $0.id == plugin.id }) { items.append(plugin) }
        return items.sorted { lhs, rhs in
            if lhs.id == "org.framo.syncthing" { return true }
            if rhs.id == "org.framo.syncthing" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    init() { reloadExternalPlugins() }

    func isBuiltIn(_ id: String) -> Bool { Self.builtInCatalog.contains { $0.id == id } }

    func canInstall(_ id: String) -> Bool {
        guard let plugin = catalog.first(where: { $0.id == id }) else { return false }
        if !isBuiltIn(id) { return true }
        return !plugin.actions.isEmpty
    }

    func isRuntimeReady(_ id: String) -> Bool {
        switch id {
        case "org.framo.syncthing", "org.framo.native-export", "org.framo.checksum", "org.framo.archive", "org.framo.finder", "org.framo.rsync", "org.framo.taskkit", "org.framo.calendar-kit", "org.framo.quicklook", "org.framo.spotlight":
            return true
        case "org.framo.ffmpeg":
            return locateTool("ffmpeg") != nil
        case "org.framo.mediainfo":
            return locateTool("mediainfo") != nil
        case "org.framo.exiftool":
            return locateTool("exiftool") != nil
        case "org.framo.imagemagick":
            return locateTool("magick") != nil || locateTool("convert") != nil
        case "org.framo.git":
            return locateTool("git") != nil
        case "org.framo.otio":
            return locateTool("otioconvert") != nil
        case "org.framo.rclone":
            return locateTool("rclone") != nil
        case "org.framo.restic":
            return locateTool("restic") != nil
        case "org.framo.webtorrent":
            return locateTool("webtorrent") != nil || locateTool("webtorrent-hybrid") != nil
        default:
            return !isBuiltIn(id)
        }
    }

    func runtimeStatus(for id: String) -> String {
        switch id {
        case "org.framo.syncthing": return "Installed · configure Syncthing below"
        case "org.framo.ffmpeg": return locateTool("ffmpeg") != nil ? "FFmpeg is ready" : "Install FFmpeg to activate"
        case "org.framo.mediainfo": return locateTool("mediainfo") != nil ? "MediaInfo is ready" : "Install MediaInfo to activate"
        case "org.framo.exiftool": return locateTool("exiftool") != nil ? "ExifTool is ready" : "Install ExifTool to activate"
        case "org.framo.imagemagick": return (locateTool("magick") != nil || locateTool("convert") != nil) ? "ImageMagick is ready" : "Install ImageMagick to activate"
        case "org.framo.git": return locateTool("git") != nil ? "Git is ready" : "Git binary not found"
        case "org.framo.otio": return locateTool("otioconvert") != nil ? "OpenTimelineIO is ready" : "Install OpenTimelineIO CLI to activate"
        case "org.framo.rclone": return locateTool("rclone") != nil ? "rclone is ready" : "Install rclone to activate"
        case "org.framo.restic": return locateTool("restic") != nil ? "restic is ready" : "Install restic to activate"
        case "org.framo.webtorrent": return (locateTool("webtorrent") != nil || locateTool("webtorrent-hybrid") != nil) ? "WebTorrent is ready" : "Install webtorrent-cli to activate"
        case "org.framo.finder", "org.framo.rsync", "org.framo.taskkit", "org.framo.calendar-kit", "org.framo.native-export", "org.framo.checksum", "org.framo.archive", "org.framo.quicklook", "org.framo.spotlight": return "Ready"
        default:
            if let plugin = catalog.first(where: { $0.id == id }), plugin.actions.isEmpty { return "Adapter not implemented yet" }
            return "Ready"
        }
    }

    func actions(installedIDs: [String], disabledIDs: [String], target: PluginTarget, fileExtension: String?) -> [RegisteredPluginAction] {
        catalog
            .filter { installedIDs.contains($0.id) && !disabledIDs.contains($0.id) && isRuntimeReady($0.id) }
            .flatMap { plugin in
                plugin.actions.filter { $0.supports(target: target, fileExtension: fileExtension) }.map { RegisteredPluginAction(plugin: plugin, action: $0) }
            }
    }

    func inspectPackage(at source: URL) throws -> FramoPluginManifest {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw PluginRuntimeError.missingManifest }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FramoPluginManifest.self, from: data)
        guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PluginRuntimeError.invalidManifest }
        return manifest
    }

    func installPackage(from source: URL) throws -> FramoPluginManifest {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw PluginRuntimeError.missingManifest }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FramoPluginManifest.self, from: data)
        guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PluginRuntimeError.invalidManifest }
        if let executable = manifest.executable {
            let candidate = source.appendingPathComponent(executable).standardizedFileURL
            guard candidate.path.hasPrefix(source.standardizedFileURL.path + "/") || candidate == source.standardizedFileURL,
                  FileManager.default.fileExists(atPath: candidate.path) else { throw PluginRuntimeError.missingExecutable }
        }
        let destination = pluginsRoot.appendingPathComponent("\(manifest.id).framo-plugin", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        reloadExternalPlugins()
        return manifest
    }

    func removeExternalPlugin(id: String) {
        guard let root = packageRoots[id] else { return }
        try? FileManager.default.removeItem(at: root)
        reloadExternalPlugins()
    }

    func runExternal(plugin: FramoPluginManifest, action: PluginActionManifest, context: PluginInvocationContext, completion: @escaping (String) -> Void) {
        guard let root = packageRoots[plugin.id], let executable = plugin.executable else {
            completion("\(plugin.name) is an adapter only. Install or configure its external tool first.")
            return
        }
        let executableURL = root.appendingPathComponent(executable).standardizedFileURL
        guard executableURL.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            completion("\(plugin.name)'s executable is missing or not executable.")
            return
        }
        do {
            let input = try JSONEncoder().encode(context)
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [action.id]
            var environment = ProcessInfo.processInfo.environment
            environment["FRAMO_PLUGIN_API_VERSION"] = "1"
            process.environment = environment
            let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errorData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                if process.terminationStatus == 0 {
                    if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                       let body = object["message"] as? String { completion(body) }
                    else { completion("\(plugin.name) finished \(action.label.lowercased()).") }
                } else {
                    let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion("\(plugin.name) failed" + ((detail?.isEmpty == false) ? ": \(detail!)" : "."))
                }
            }
        } catch {
            completion("Couldn’t launch \(plugin.name): \(error.localizedDescription)")
        }
    }

    func canAutoInstallRuntime(_ pluginID: String) -> Bool {
        runtimeInstallFormula(for: pluginID) != nil || pluginID == "org.framo.otio"
    }

    func installRuntime(for pluginID: String, completion: @escaping (String) -> Void) {
        if isRuntimeReady(pluginID) {
            completion("Runtime is already ready.")
            return
        }

        if pluginID == "org.framo.otio" {
            guard let python = locateTool("python3") else {
                completion("Python 3 wasn't found. Install Python, then try again or use Locate runtime…")
                return
            }
            runInstaller(executable: python, arguments: ["-m", "pip", "install", "--user", "OpenTimelineIO"]) { [weak self] status, detail in
                DispatchQueue.main.async {
                    self?.customRuntimeRevision &+= 1
                    completion(status == 0 ? "OpenTimelineIO installed. Restart MODO if otioconvert is not detected immediately." : "OpenTimelineIO install failed" + (detail.isEmpty ? "." : ": \(detail)"))
                }
            }
            return
        }

        guard let formula = runtimeInstallFormula(for: pluginID) else {
            completion("This runtime can't be installed automatically. Use Locate runtime…")
            return
        }
        guard let brew = locateHomebrew() else {
            completion("Homebrew wasn't found. MODO checked /opt/homebrew, /usr/local and your PATH. If Homebrew was just installed, relaunch MODO or use Locate runtime…")
            return
        }
        completion("Installing \(formula) with Homebrew…")
        runInstaller(executable: brew, arguments: ["install", formula]) { [weak self] status, detail in
            DispatchQueue.main.async {
                self?.customRuntimeRevision &+= 1
                if status == 0 {
                    completion("Installed \(formula). The plugin is ready.")
                } else {
                    completion("Homebrew install failed" + (detail.isEmpty ? "." : ": \(detail)"))
                }
            }
        }
    }

    private func runtimeInstallFormula(for pluginID: String) -> String? {
        switch pluginID {
        case "org.framo.ffmpeg": return "ffmpeg"
        case "org.framo.mediainfo": return "media-info"
        case "org.framo.exiftool": return "exiftool"
        case "org.framo.imagemagick": return "imagemagick"
        case "org.framo.git": return "git"
        case "org.framo.rclone": return "rclone"
        case "org.framo.restic": return "restic"
        case "org.framo.webtorrent": return "webtorrent-cli"
        case "org.framo.syncthing": return "syncthing"
        default: return nil
        }
    }

    private func runInstaller(executable: URL, arguments: [String], completion: @escaping (Int32, String) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        let injectedPaths = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        environment["PATH"] = (injectedPaths + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                completion(process.terminationStatus, detail)
            }
        } catch {
            completion(-1, error.localizedDescription)
        }
    }

    func chooseRuntime(for pluginID: String) -> String {
        guard let tool = runtimeToolName(for: pluginID) else { return "This plugin doesn't use an external runtime." }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use \(tool)"
        panel.message = "Choose the \(tool) executable. MODO will remember it securely."
        guard panel.runModal() == .OK, let url = panel.url else { return "Runtime selection cancelled." }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return "That file isn't executable." }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = runtimeBookmarks()
            bookmarks[tool] = bookmark.base64EncodedString()
            if let encoded = try? JSONEncoder().encode(bookmarks) {
                UserDefaults.standard.set(encoded, forKey: runtimeBookmarksKey)
            }
            customRuntimeRevision &+= 1
            return "Using \(url.lastPathComponent) for \(pluginID.components(separatedBy: ".").last ?? pluginID)."
        } catch {
            return "Couldn't remember the runtime: \(error.localizedDescription)"
        }
    }

    private func runtimeToolName(for pluginID: String) -> String? {
        switch pluginID {
        case "org.framo.ffmpeg": return "ffmpeg"
        case "org.framo.mediainfo": return "mediainfo"
        case "org.framo.exiftool": return "exiftool"
        case "org.framo.imagemagick": return "magick"
        case "org.framo.git": return "git"
        case "org.framo.otio": return "otioconvert"
        case "org.framo.rclone": return "rclone"
        case "org.framo.restic": return "restic"
        case "org.framo.webtorrent": return "webtorrent"
        default: return nil
        }
    }

    private func runtimeBookmarks() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: runtimeBookmarksKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func customRuntimeURL(for tool: String) -> URL? {
        if let existing = scopedRuntimeURLs[tool], FileManager.default.isExecutableFile(atPath: existing.path) { return existing }
        guard let encoded = runtimeBookmarks()[tool], let data = Data(base64Encoded: encoded) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        if url.startAccessingSecurityScopedResource() { scopedRuntimeURLs[tool] = url }
        return url
    }

    func runBuiltInTool(pluginID: String, actionID: String, url: URL, completion: @escaping (String) -> Void) {
        switch pluginID {
        case "org.framo.ffmpeg": runFFmpeg(actionID: actionID, input: url, completion: completion)
        case "org.framo.mediainfo": runInspector(tool: "mediainfo", arguments: [url.path], title: "MediaInfo", completion: completion)
        case "org.framo.exiftool": runInspector(tool: "exiftool", arguments: ["-G", "-a", "-s", url.path], title: "ExifTool", completion: completion)
        case "org.framo.imagemagick": runImageMagick(actionID: actionID, input: url, completion: completion)
        case "org.framo.checksum": runChecksum(actionID: actionID, input: url, completion: completion)
        case "org.framo.archive": runArchive(actionID: actionID, input: url, completion: completion)
        case "org.framo.otio": runOTIO(actionID: actionID, input: url, completion: completion)
        case "org.framo.finder": runFinderAction(actionID: actionID, input: url, completion: completion)
        case "org.framo.rsync": runRsync(actionID: actionID, input: url, completion: completion)
        case "org.framo.webtorrent": runWebTorrent(actionID: actionID, input: url, completion: completion)
        case "org.framo.quicklook": runQuickLook(input: url, completion: completion)
        case "org.framo.spotlight": runSpotlightMetadata(input: url, completion: completion)
        default: completion("This adapter has no built-in action yet.")
        }
    }

    private func runFFmpeg(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        guard let executable = locateTool("ffmpeg") else { completion("FFmpeg wasn't found. Install ffmpeg or provide it through a .framo-plugin package."); return }
        let base = input.deletingPathExtension().lastPathComponent
        let directory = input.deletingLastPathComponent()
        let output: URL
        let arguments: [String]
        switch actionID {
        case "thumbnail":
            output = uniqueURL(in: directory, base: base + "-thumbnail", ext: "jpg")
            arguments = ["-hide_banner", "-nostdin", "-n", "-ss", "00:00:01", "-i", input.path, "-frames:v", "1", "-q:v", "2", output.path]
        case "extract-audio":
            output = uniqueURL(in: directory, base: base + "-audio", ext: "wav")
            arguments = ["-hide_banner", "-nostdin", "-n", "-i", input.path, "-vn", "-c:a", "pcm_s24le", output.path]
        case "proxy":
            output = uniqueURL(in: directory, base: base + "-proxy", ext: "mov")
            arguments = ["-hide_banner", "-nostdin", "-n", "-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-vf", "scale=-2:1080", "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", output.path]
        default:
            completion("Unknown FFmpeg action."); return
        }
        runProcess(executable: executable, arguments: arguments) { status, errorText in
            if status == 0 { completion("Created \(output.lastPathComponent).") }
            else { completion("FFmpeg failed" + (errorText.isEmpty ? "." : ": \(errorText)")) }
        }
    }

    func runProjectUtility(pluginID: String, actionID: String, completion: @escaping (String) -> Void) {
        let tool: String
        let arguments: [String]
        switch pluginID {
        case "org.framo.rclone": tool = "rclone"; arguments = ["listremotes"]
        case "org.framo.restic": tool = "restic"; arguments = ["version"]
        case "org.framo.git": tool = "git"; arguments = ["--version"]
        case "org.framo.webtorrent":
            for (_, process) in activeWebTorrentProcesses { if process.isRunning { process.terminate() } }
            activeWebTorrentProcesses.removeAll()
            completion("Stopped all MODO WebTorrent seeds.")
            return
        default: completion("Unknown project utility."); return
        }
        guard let executable = locateTool(tool) else { completion("\(tool) wasn't found on this Mac."); return }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let out = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let body = String(data: process.terminationStatus == 0 ? out : err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                completion(body.isEmpty ? "\(tool) finished." : body)
            }
        } catch { completion("Couldn’t launch \(tool): \(error.localizedDescription)") }
    }

    private func runFinderAction(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        switch actionID {
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([input])
            completion("Revealed \(input.lastPathComponent) in Finder.")
        case "copy-path":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(input.path, forType: .string)
            completion("Copied file path.")
        case "copy-name":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(input.lastPathComponent, forType: .string)
            completion("Copied file name.")
        default:
            completion("Unknown Finder action.")
        }
    }

    private func runRsync(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        guard actionID == "copy" else { completion("Unknown rsync action."); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Copy here"
        guard panel.runModal() == .OK, let destination = panel.url else { completion("Copy cancelled."); return }
        let executable = URL(fileURLWithPath: "/usr/bin/rsync")
        let target = destination.appendingPathComponent(input.lastPathComponent)
        runProcess(executable: executable, arguments: ["-a", "--", input.path, target.path]) { status, detail in
            completion(status == 0 ? "Copied \(input.lastPathComponent) to \(destination.lastPathComponent)." : "rsync failed" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    private func runWebTorrent(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        guard actionID == "seed" else { completion("Unknown WebTorrent action."); return }
        guard let executable = locateTool("webtorrent") ?? locateTool("webtorrent-hybrid") else {
            completion("WebTorrent CLI wasn't found. Install webtorrent-cli to enable browser-compatible P2P delivery.")
            return
        }
        let process = Process()
        let identifier = UUID()
        process.executableURL = executable
        process.arguments = ["seed", input.path, "--keep-seeding"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let seedState = FramoWebTorrentSeedState()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            seedState.lock.lock()
            seedState.buffer += chunk
            let buffer = seedState.buffer
            let alreadyPublished = seedState.didPublish
            seedState.lock.unlock()
            guard !alreadyPublished, let range = buffer.range(of: "magnet:?") else { return }
            let tail = buffer[range.lowerBound...]
            let magnet = tail.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " }).first.map(String.init) ?? ""
            guard !magnet.isEmpty else { return }
            seedState.lock.lock()
            guard !seedState.didPublish else { seedState.lock.unlock(); return }
            seedState.didPublish = true
            seedState.lock.unlock()
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(magnet, forType: .string)
                completion("P2P seed is live. Magnet link copied to clipboard; keep MODO and this Mac online while clients download.")
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.activeWebTorrentProcesses[identifier] = nil }
        }
        do {
            try process.run()
            activeWebTorrentProcesses[identifier] = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                seedState.lock.lock()
                let published = seedState.didPublish
                seedState.lock.unlock()
                if !published { completion("WebTorrent seed started. Waiting for the magnet link…") }
            }
        } catch {
            completion("Couldn't start WebTorrent: \(error.localizedDescription)")
        }
    }

    private func runQuickLook(input: URL, completion: @escaping (String) -> Void) {
        let executable = URL(fileURLWithPath: "/usr/bin/qlmanage")
        runProcess(executable: executable, arguments: ["-p", input.path]) { status, detail in
            completion(status == 0 ? "Opened Quick Look preview." : "Quick Look failed" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    private func runSpotlightMetadata(input: URL, completion: @escaping (String) -> Void) {
        let executable = URL(fileURLWithPath: "/usr/bin/mdls")
        let process = Process(); process.executableURL = executable; process.arguments = [input.path]
        let stdout = Pipe(); process.standardOutput = stdout; process.standardError = Pipe()
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MODO-Spotlight-\(UUID().uuidString.prefix(6)).txt")
                try? data.write(to: destination)
                DispatchQueue.main.async { NSWorkspace.shared.open(destination) }
                completion(process.terminationStatus == 0 ? "Opened Spotlight metadata." : "Spotlight metadata failed.")
            }
        } catch { completion("Spotlight metadata failed: \(error.localizedDescription)") }
    }

    private func runOTIO(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        guard actionID == "inspect-timeline" else { completion("Unknown OpenTimelineIO action."); return }
        guard let executable = locateTool("otioconvert") else { completion("OpenTimelineIO CLI wasn't found on this Mac."); return }
        let output = uniqueURL(in: input.deletingLastPathComponent(), base: input.deletingPathExtension().lastPathComponent + "-converted", ext: "otio")
        runProcess(executable: executable, arguments: ["-i", input.path, "-o", output.path]) { status, detail in
            completion(status == 0 ? "Created \(output.lastPathComponent)." : "OpenTimelineIO failed" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    private func runImageMagick(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        guard let executable = locateTool("magick") ?? locateTool("convert") else { completion("ImageMagick wasn't found on this Mac."); return }
        let directory = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let output: URL
        let arguments: [String]
        switch actionID {
        case "jpg":
            output = uniqueURL(in: directory, base: base + "-converted", ext: "jpg")
            arguments = executable.lastPathComponent == "magick" ? [input.path, "-quality", "92", output.path] : [input.path, "-quality", "92", output.path]
        case "half-size":
            output = uniqueURL(in: directory, base: base + "-50pct", ext: input.pathExtension.isEmpty ? "png" : input.pathExtension)
            arguments = executable.lastPathComponent == "magick" ? [input.path, "-resize", "50%", output.path] : [input.path, "-resize", "50%", output.path]
        default:
            completion("Unknown ImageMagick action."); return
        }
        runProcess(executable: executable, arguments: arguments) { status, detail in
            completion(status == 0 ? "Created \(output.lastPathComponent)." : "ImageMagick failed" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    private func runChecksum(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        let algorithm = actionID == "sha1" ? "1" : "256"
        guard let executable = locateTool("shasum") ?? URL(string: "file:///usr/bin/shasum") else { completion("shasum wasn't found."); return }
        let process = Process(); process.executableURL = executable; process.arguments = ["-a", algorithm, input.path]
        let stdout = Pipe(); process.standardOutput = stdout; process.standardError = Pipe()
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let value = String(data: data, encoding: .utf8)?.split(separator: " ").first.map(String.init) ?? ""
                DispatchQueue.main.async {
                    if !value.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                    completion(value.isEmpty ? "Checksum failed." : "Copied SHA-\(algorithm) checksum to clipboard.")
                }
            }
        } catch { completion("Checksum failed: \(error.localizedDescription)") }
    }

    private func runArchive(actionID: String, input: URL, completion: @escaping (String) -> Void) {
        guard actionID == "zip" else { completion("Unknown archive action."); return }
        let output = uniqueURL(in: input.deletingLastPathComponent(), base: input.deletingPathExtension().lastPathComponent + "-archive", ext: "zip")
        let executable = URL(fileURLWithPath: "/usr/bin/ditto")
        runProcess(executable: executable, arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, output.path]) { status, detail in
            completion(status == 0 ? "Created \(output.lastPathComponent)." : "Archive failed" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    private func runInspector(tool: String, arguments: [String], title: String, completion: @escaping (String) -> Void) {
        guard let executable = locateTool(tool) else { completion("\(title) wasn't found on this Mac."); return }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errorData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                guard process.terminationStatus == 0 else {
                    completion("\(title) failed: \(String(data: errorData, encoding: .utf8) ?? "Unknown error")")
                    return
                }
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MODO-\(title)-\(UUID().uuidString.prefix(6)).txt")
                try? data.write(to: destination)
                DispatchQueue.main.async { NSWorkspace.shared.open(destination) }
                completion("Opened \(title) metadata report.")
            }
        } catch { completion("Couldn’t launch \(title): \(error.localizedDescription)") }
    }

    private func runProcess(executable: URL, arguments: [String], completion: @escaping (Int32, String) -> Void) {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let stderr = Pipe(); process.standardError = stderr; process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                completion(process.terminationStatus, text)
            }
        } catch { completion(-1, error.localizedDescription) }
    }

    private func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index)").appendingPathExtension(ext); index += 1
        }
        return candidate
    }

    private func locateTool(_ name: String) -> URL? {
        if let custom = customRuntimeURL(for: name), isRunnableExecutable(custom) { return custom }
        if name == "brew", let brew = locateHomebrew() { return brew }

        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchRoots = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            home + "/.local/bin",
            home + "/bin"
        ] + environmentPaths

        var seen = Set<String>()
        for root in searchRoots where seen.insert(root).inserted {
            let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name)
            if isRunnableExecutable(url) { return url.resolvingSymlinksInPath() }
        }
        return nil
    }

    private func locateHomebrew() -> URL? {
        let explicit = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew"
        ]
        for path in explicit {
            let url = URL(fileURLWithPath: path)
            if isRunnableExecutable(url) { return url.resolvingSymlinksInPath() }
        }

        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for root in environmentPaths {
            let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("brew")
            if isRunnableExecutable(url) { return url.resolvingSymlinksInPath() }
        }
        return nil
    }

    private func isRunnableExecutable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let directPath = url.path
        let resolvedPath = url.resolvingSymlinksInPath().path
        return (fileManager.fileExists(atPath: directPath) && fileManager.isExecutableFile(atPath: directPath))
            || (fileManager.fileExists(atPath: resolvedPath) && fileManager.isExecutableFile(atPath: resolvedPath))
    }

    private var pluginsRoot: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bywarre Studio/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func reloadExternalPlugins() {
        var manifests: [FramoPluginManifest] = []
        var roots: [String: URL] = [:]
        let children = (try? FileManager.default.contentsOfDirectory(at: pluginsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for root in children where root.hasDirectoryPath {
            let manifestURL = root.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(FramoPluginManifest.self, from: data) else { continue }
            manifests.append(manifest); roots[manifest.id] = root
        }
        externalPlugins = manifests; packageRoots = roots
    }

    private static let builtInCatalog: [FramoPluginManifest] = [
        FramoPluginManifest(id: "org.framo.syncthing", name: "Syncthing", version: "1.0", author: "MODO adapter", summary: "Continuous encrypted peer-to-peer project folder synchronization across Macs, desktops and NAS devices.", license: "MPL-2.0", permissions: [.projectData, .externalVolumes, .network, .backgroundProcess], actions: [
            PluginActionManifest(id: "configure-project", label: "Configure Syncthing…", targets: [.project]),
            PluginActionManifest(id: "rescan-project", label: "Rescan Syncthing folder", targets: [.project]),
            PluginActionManifest(id: "sync-containing-folder", label: "Sync containing folder…", targets: [.linkedFile])
        ], sourceURL: "https://github.com/syncthing/syncthing", homepageURL: "https://syncthing.net", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.ffmpeg", name: "FFmpeg", version: "1.0", author: "MODO adapter", summary: "Proxy creation, audio extraction and media conversion from linked production files.", license: "LGPL/GPL depending on build", permissions: [.linkedFiles, .externalVolumes, .backgroundProcess], actions: [
            PluginActionManifest(id: "proxy", label: "Generate 1080p ProRes proxy", targets: [.linkedFile], supportedExtensions: ["mov","mp4","mxf","mkv","avi","mts","m2ts"]),
            PluginActionManifest(id: "extract-audio", label: "Extract WAV audio", targets: [.linkedFile], supportedExtensions: ["mov","mp4","mxf","mkv","avi","mts","m2ts"]),
            PluginActionManifest(id: "thumbnail", label: "Extract JPEG thumbnail", targets: [.linkedFile], supportedExtensions: ["mov","mp4","mxf","mkv","avi","mts","m2ts"])
        ], sourceURL: "https://github.com/FFmpeg/FFmpeg", homepageURL: "https://ffmpeg.org", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.mediainfo", name: "MediaInfo", version: "1.0", author: "MODO adapter", summary: "Inspect codecs, bitrates, frame rates, audio tracks and container metadata.", license: "BSD-2-Clause", permissions: [.linkedFiles, .backgroundProcess], actions: [PluginActionManifest(id: "inspect", label: "Inspect with MediaInfo", targets: [.linkedFile])], sourceURL: "https://github.com/MediaArea/MediaInfo", homepageURL: "https://mediaarea.net/MediaInfo", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.exiftool", name: "ExifTool", version: "1.0", author: "MODO adapter", summary: "Read detailed camera, lens, timecode, GPS and production metadata.", license: "Artistic/GPL", permissions: [.linkedFiles, .backgroundProcess], actions: [PluginActionManifest(id: "inspect", label: "Inspect with ExifTool", targets: [.linkedFile])], sourceURL: "https://github.com/exiftool/exiftool", homepageURL: "https://exiftool.org", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.otio", name: "OpenTimelineIO", version: "1.0", author: "MODO adapter", summary: "Timeline interchange and editorial metadata workflows.", license: "Apache-2.0", permissions: [.projectData, .linkedFiles, .backgroundProcess], actions: [PluginActionManifest(id: "inspect-timeline", label: "Inspect timeline with OTIO", targets: [.linkedFile], supportedExtensions: ["otio","edl","xml","fcpxml"])], sourceURL: "https://github.com/AcademySoftwareFoundation/OpenTimelineIO", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.rclone", name: "rclone", version: "1.0", author: "MODO adapter", summary: "Connect S3, B2, SFTP, WebDAV and dozens of remote storage providers.", license: "MIT", permissions: [.linkedFiles, .externalVolumes, .network, .backgroundProcess], actions: [PluginActionManifest(id: "show-remotes", label: "Show configured rclone remotes", targets: [.project])], sourceURL: "https://github.com/rclone/rclone", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.restic", name: "restic", version: "1.0", author: "MODO adapter", summary: "Encrypted, deduplicated project backups to local or remote storage.", license: "BSD-2-Clause", permissions: [.linkedFiles, .externalVolumes, .network, .backgroundProcess], actions: [PluginActionManifest(id: "version", label: "Check restic runtime", targets: [.project])], sourceURL: "https://github.com/restic/restic", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.imagemagick", name: "ImageMagick", version: "1.0", author: "MODO adapter", summary: "Image conversion and production still utilities.", license: "ImageMagick", permissions: [.linkedFiles, .externalVolumes, .backgroundProcess], actions: [PluginActionManifest(id: "jpg", label: "Convert image to JPEG", targets: [.linkedFile], supportedExtensions: ["png","tif","tiff","heic","webp","jpg","jpeg"]), PluginActionManifest(id: "half-size", label: "Create 50% image copy", targets: [.linkedFile], supportedExtensions: ["png","tif","tiff","heic","webp","jpg","jpeg"])], sourceURL: "https://github.com/ImageMagick/ImageMagick", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.git", name: "Git", version: "1.0", author: "MODO adapter", summary: "Version scripts, briefs and lightweight project metadata.", license: "GPL-2.0", permissions: [.projectData, .externalVolumes, .backgroundProcess], actions: [PluginActionManifest(id: "version", label: "Check Git runtime", targets: [.project])], sourceURL: "https://github.com/git/git", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.native-export", name: "MODO Export Kit", version: "1.0", author: "MODO", summary: "Export work summaries, production lists and task lists without leaving MODO.", license: "Built-in", permissions: [.projectData], actions: [PluginActionManifest(id: "project-summary", label: "Export work summary", targets: [.project]), PluginActionManifest(id: "shotlist-csv", label: "Export shot list CSV", targets: [.project]), PluginActionManifest(id: "tasks-csv", label: "Export task list CSV", targets: [.project]), PluginActionManifest(id: "call-sheet", label: "Export call sheet draft", targets: [.project]), PluginActionManifest(id: "delivery-manifest", label: "Export delivery manifest", targets: [.project])], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.checksum", name: "Checksums", version: "1.0", author: "MODO", summary: "Generate verification hashes for large media handoffs.", license: "Built-in", permissions: [.linkedFiles, .backgroundProcess], actions: [PluginActionManifest(id: "sha256", label: "Copy SHA-256 checksum", targets: [.linkedFile]), PluginActionManifest(id: "sha1", label: "Copy SHA-1 checksum", targets: [.linkedFile])], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.archive", name: "Archive", version: "1.0", author: "MODO", summary: "Create ZIP archives from linked production files using macOS tools.", license: "Built-in", permissions: [.linkedFiles, .externalVolumes, .backgroundProcess], actions: [PluginActionManifest(id: "zip", label: "Create ZIP archive", targets: [.linkedFile])], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.finder", name: "Finder Tools", version: "1.0", author: "MODO", summary: "Native macOS file actions everywhere linked media appears.", license: "Built-in", permissions: [.linkedFiles], actions: [
            PluginActionManifest(id: "reveal", label: "Reveal in Finder", targets: [.linkedFile]),
            PluginActionManifest(id: "copy-path", label: "Copy file path", targets: [.linkedFile]),
            PluginActionManifest(id: "copy-name", label: "Copy file name", targets: [.linkedFile])
        ], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.quicklook", name: "Quick Look", version: "1.0", author: "MODO", summary: "Preview linked media instantly with macOS Quick Look.", license: "Built-in macOS tool", permissions: [.linkedFiles, .backgroundProcess], actions: [PluginActionManifest(id: "preview", label: "Open Quick Look preview", targets: [.linkedFile])], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.spotlight", name: "Spotlight Metadata", version: "1.0", author: "MODO", summary: "Inspect native macOS metadata for any linked file without another dependency.", license: "Built-in macOS tool", permissions: [.linkedFiles, .backgroundProcess], actions: [PluginActionManifest(id: "inspect", label: "Inspect Spotlight metadata", targets: [.linkedFile])], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.rsync", name: "rsync Handoff", version: "1.0", author: "MODO", summary: "Copy very large linked files to another mounted drive with macOS rsync.", license: "Built-in macOS tool", permissions: [.linkedFiles, .externalVolumes, .backgroundProcess], actions: [
            PluginActionManifest(id: "copy", label: "Copy to drive with rsync…", targets: [.linkedFile])
        ], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.webtorrent", name: "WebTorrent P2P", version: "1.0", author: "MODO adapter", summary: "Seed a linked deliverable directly to WebRTC/WebTorrent-capable peers. No MODO cloud storage.", license: "MIT", permissions: [.linkedFiles, .network, .backgroundProcess], actions: [
            PluginActionManifest(id: "seed", label: "Seed P2P + copy magnet link", targets: [.linkedFile]),
            PluginActionManifest(id: "stop", label: "Stop all P2P seeds", targets: [.project])
        ], sourceURL: "https://github.com/webtorrent/webtorrent-cli", homepageURL: "https://webtorrent.io", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.taskkit", name: "Task Kit", version: "1.0", author: "MODO", summary: "Fast native task actions available from task context menus across MODO.", license: "Built-in", permissions: [.projectData], actions: [
            PluginActionManifest(id: "copy-markdown", label: "Copy task as Markdown", targets: [.task]),
            PluginActionManifest(id: "tomorrow", label: "Set deadline tomorrow", targets: [.task]),
            PluginActionManifest(id: "toggle", label: "Complete / reopen task", targets: [.task])
        ], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.calendar-kit", name: "Calendar Kit", version: "1.0", author: "MODO", summary: "Bridge project deadlines and MODO plans into the calendar workflow.", license: "Built-in", permissions: [.projectData], actions: [
            PluginActionManifest(id: "deadline-event", label: "Add project deadline to calendar", targets: [.project]),
            PluginActionManifest(id: "push-apple", label: "Push MODO plans to Apple Calendar", targets: [.project])
        ], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.kitsu", name: "Kitsu", version: "1.0", author: "MODO adapter", summary: "Open-source production tracking bridge for teams and studios.", license: "AGPL-3.0", permissions: [.projectData, .network], actions: [], sourceURL: "https://github.com/cgwire/kitsu", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.s3", name: "S3 / MinIO", version: "1.0", author: "MODO adapter", summary: "Self-hosted or S3-compatible object storage for archives and deliveries.", license: "Adapter", permissions: [.linkedFiles, .network], actions: [], homepageURL: "https://min.io", builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.webdav", name: "WebDAV", version: "1.0", author: "MODO adapter", summary: "Generic NAS and self-hosted file server connector.", license: "Adapter", permissions: [.linkedFiles, .network], actions: [], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.sftp", name: "SFTP / SSH", version: "1.0", author: "MODO adapter", summary: "Direct transfers to remote edit stations, NAS devices and servers.", license: "Adapter", permissions: [.linkedFiles, .network], actions: [], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.discord", name: "Discord Webhooks", version: "1.0", author: "MODO adapter", summary: "Send production and delivery notifications to Discord.", license: "Adapter", permissions: [.projectData, .network, .notifications], actions: [], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.slack", name: "Slack Webhooks", version: "1.0", author: "MODO adapter", summary: "Send review, task and delivery updates to Slack.", license: "Adapter", permissions: [.projectData, .network, .notifications], actions: [], builtInAdapter: true),
        FramoPluginManifest(id: "org.framo.frameio", name: "Frame.io", version: "1.0", author: "MODO adapter", summary: "Review-link and delivery workflow integration.", license: "Adapter", permissions: [.projectData, .linkedFiles, .network], actions: [], homepageURL: "https://frame.io", builtInAdapter: true)
    ]

    private enum PluginRuntimeError: LocalizedError {
        case missingManifest, invalidManifest, missingExecutable
        var errorDescription: String? {
            switch self {
            case .missingManifest: "The plugin package doesn't contain manifest.json."
            case .invalidManifest: "The plugin manifest is invalid."
            case .missingExecutable: "The executable declared by this plugin is missing."
            }
        }
    }
}

@MainActor
final class FramoV5SyncthingService: ObservableObject {
    @Published private(set) var status = "Not connected"
    @Published private(set) var isReachable = false
    @Published private(set) var localDeviceID = ""
    @Published private(set) var version = ""
    @Published private(set) var devices: [SyncthingDevice] = []
    @Published private(set) var folders: [SyncthingFolder] = []
    @Published private(set) var folderStatuses: [String: SyncthingFolderStatus] = [:]
    @Published private(set) var managedRunning = false

    private var baseURL = URL(string: "http://127.0.0.1:8384")!
    private var apiKey = ""
    private var managedProcess: Process?
    private var scopedExecutableURL: URL?

    func configure(baseURL: String, apiKey: String) {
        if let parsed = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.scheme != nil { self.baseURL = parsed }
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh() async {
        do {
            let statusData = try await request("/rest/system/status")
            let statusObject = try jsonDictionary(statusData)
            localDeviceID = statusObject["myID"] as? String ?? localDeviceID
            version = statusObject["version"] as? String ?? version

            let deviceData = try await request("/rest/config/devices")
            let folderData = try await request("/rest/config/folders")
            let connectionData = try await request("/rest/system/connections")
            let deviceObjects = try jsonArray(deviceData)
            let folderObjects = try jsonArray(folderData)
            let connections = (try jsonDictionary(connectionData)["connections"] as? [String: Any]) ?? [:]

            devices = deviceObjects.compactMap { object in
                guard let id = object["deviceID"] as? String, id != localDeviceID else { return nil }
                let connection = connections[id] as? [String: Any]
                return SyncthingDevice(
                    deviceID: id,
                    name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(id.prefix(7)),
                    connected: connection?["connected"] as? Bool ?? false,
                    paused: object["paused"] as? Bool ?? false,
                    address: connection?["address"] as? String ?? ""
                )
            }
            folders = folderObjects.compactMap { object in
                guard let id = object["id"] as? String else { return nil }
                let devices = (object["devices"] as? [[String: Any]] ?? []).compactMap { $0["deviceID"] as? String }.filter { $0 != localDeviceID }
                return SyncthingFolder(id: id, label: object["label"] as? String ?? id, path: object["path"] as? String ?? "", paused: object["paused"] as? Bool ?? false, deviceIDs: devices)
            }
            isReachable = true
            status = devices.filter(\.connected).isEmpty ? "Connected · no remote device online" : "Connected · \(devices.filter(\.connected).count) device\(devices.filter(\.connected).count == 1 ? "" : "s") online"
        } catch {
            isReachable = false
            status = "Syncthing unavailable"
        }
    }

    func refreshFolderStatus(folderID: String) async {
        do {
            let data = try await request("/rest/db/status", query: [URLQueryItem(name: "folder", value: folderID)])
            let object = try jsonDictionary(data)
            folderStatuses[folderID] = SyncthingFolderStatus(
                state: object["state"] as? String ?? "unknown",
                globalBytes: int64(object["globalBytes"]),
                inSyncBytes: int64(object["inSyncBytes"]),
                needBytes: int64(object["needBytes"]),
                needFiles: Int(int64(object["needFiles"]))
            )
        } catch { }
    }

    func addOrUpdateFolder(folderID: String, label: String, path: String, deviceIDs: [String]) async throws {
        guard !apiKey.isEmpty else { throw SyncthingError.missingAPIKey }
        let templateData = try await request("/rest/config/defaults/folder")
        var template = try jsonDictionary(templateData)
        template["id"] = folderID
        template["label"] = label
        template["path"] = path
        template["paused"] = false
        let everyDevice = ([localDeviceID] + deviceIDs).filter { !$0.isEmpty }
        template["devices"] = everyDevice.map { ["deviceID": $0] }
        let body = try JSONSerialization.data(withJSONObject: template)
        _ = try await request("/rest/config/folders", method: "POST", body: body)
        try await rescan(folderID: folderID)
    }

    func rescan(folderID: String) async throws {
        _ = try await request("/rest/db/scan", method: "POST", query: [URLQueryItem(name: "folder", value: folderID)])
    }

    func openDashboard() { NSWorkspace.shared.open(baseURL) }

    func startManaged(executable: URL, home: URL, apiKey: String) throws {
        stopManaged()
        let accessed = executable.startAccessingSecurityScopedResource()
        if accessed { scopedExecutableURL = executable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--home=\(home.path)", "--no-browser", "--no-upgrade", "--gui-address=127.0.0.1:8384", "--gui-apikey=\(apiKey)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.managedRunning = false
                if let url = self?.scopedExecutableURL { url.stopAccessingSecurityScopedResource(); self?.scopedExecutableURL = nil }
            }
        }
        try process.run()
        managedProcess = process
        managedRunning = true
        status = "Starting managed Syncthing…"
    }

    func stopManaged() {
        if let process = managedProcess, process.isRunning { process.terminate() }
        managedProcess = nil
        managedRunning = false
        if let url = scopedExecutableURL { url.stopAccessingSecurityScopedResource(); scopedExecutableURL = nil }
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path), resolvingAgainstBaseURL: false) else { throw SyncthingError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SyncthingError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw SyncthingError.requestFailed }
        return data
    }

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncthingError.invalidResponse }
        return value
    }

    private func jsonArray(_ data: Data) throws -> [[String: Any]] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SyncthingError.invalidResponse }
        return value
    }

    private func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return 0
    }

    private enum SyncthingError: LocalizedError {
        case invalidURL, requestFailed, invalidResponse, missingAPIKey
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid Syncthing URL."
            case .requestFailed: "Syncthing rejected the request. Check the API key and local URL."
            case .invalidResponse: "Syncthing returned an unexpected response."
            case .missingAPIKey: "Enter the Syncthing API key first."
            }
        }
    }
}

enum FramoV5Keychain {
    private static let syncthingService = "be.bywarre.framo.syncthing"
    private static let credentialsService = "be.bywarre.framo.credentials"

    static func readSyncthingAPIKey() -> String? {
        read(service: syncthingService, account: "api-key")
    }

    static func saveSyncthingAPIKey(_ value: String) {
        save(value, service: syncthingService, account: "api-key")
    }

    static func readHostAccessToken() -> String? {
        read(service: credentialsService, account: "host-access-token")
    }

    static func saveHostAccessToken(_ value: String) {
        save(value, service: credentialsService, account: "host-access-token")
    }

    static func readRemoteHostToken() -> String? {
        read(service: credentialsService, account: "remote-host-token")
    }

    static func saveRemoteHostToken(_ value: String) {
        save(value, service: credentialsService, account: "remote-host-token")
    }

    static func readGoogleCredential(profileID: UUID) -> String? {
        read(service: credentialsService, account: "google-oauth-\(profileID.uuidString)")
    }

    static func saveGoogleCredential(_ value: String, profileID: UUID) {
        save(value, service: credentialsService, account: "google-oauth-\(profileID.uuidString)")
    }

    static func clearGoogleCredential(profileID: UUID) {
        delete(service: credentialsService, account: "google-oauth-\(profileID.uuidString)")
    }

    static func readFrameIOCredential(profileID: UUID) -> String? {
        read(service: credentialsService, account: "frameio-oauth-\(profileID.uuidString)")
    }

    static func saveFrameIOCredential(_ value: String, profileID: UUID) {
        save(value, service: credentialsService, account: "frameio-oauth-\(profileID.uuidString)")
    }

    static func clearFrameIOCredential(profileID: UUID) {
        delete(service: credentialsService, account: "frameio-oauth-\(profileID.uuidString)")
    }

    static func readMCPToken(profileID: UUID) -> String? {
        read(service: credentialsService, account: "mcp-token-\(profileID.uuidString)")
    }

    static func saveMCPToken(_ value: String, profileID: UUID) {
        save(value, service: credentialsService, account: "mcp-token-\(profileID.uuidString)")
    }

    static func clearMCPToken(profileID: UUID) {
        delete(service: credentialsService, account: "mcp-token-\(profileID.uuidString)")
    }


    static func readRecoveryAuthenticatorSecret(profileID: UUID) -> String? {
        read(service: credentialsService, account: "recovery-totp-\(profileID.uuidString)")
    }

    static func saveRecoveryAuthenticatorSecret(_ value: String, profileID: UUID) {
        save(value, service: credentialsService, account: "recovery-totp-\(profileID.uuidString)")
    }

    static func clearRecoveryAuthenticatorSecret(profileID: UUID) {
        delete(service: credentialsService, account: "recovery-totp-\(profileID.uuidString)")
    }

    static func clearConnectionCredentials() {
        delete(service: credentialsService, account: "host-access-token")
        delete(service: credentialsService, account: "remote-host-token")
    }

    static func clearAllKnownCredentials(profileIDs: [UUID]) {
        clearConnectionCredentials()
        delete(service: syncthingService, account: "api-key")
        for id in profileIDs {
            clearGoogleCredential(profileID: id)
            clearFrameIOCredential(profileID: id)
            clearMCPToken(profileID: id)
            clearRecoveryAuthenticatorSecret(profileID: id)
        }
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, service: String, account: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        delete(service: service, account: account)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}


// MARK: - V0.20 production workspace helpers

extension FramoStudioStore {
    func initializeProductionWorkspace() {
        if spaces.isEmpty {
            spaces = defaultSpaces(for: projects)
        }
        var pinned = settings.pinnedPages ?? []
        let essentials: [SidebarDestination] = [.home, .customers, .sales, .projects, .tasks, .calendar, .finance]
        for page in essentials where !pinned.contains(page) { pinned.append(page) }
        settings.pinnedPages = pinned
        settings.onboardingVersion = 20
        pluginNotice = "Workspace initialized"
    }

    func markOnboardingComplete() {
        settings.onboardingVersion = 20
        UserDefaults.standard.set(true, forKey: "studio.onboarding.v20.completed")
    }

    func resetOnboarding() {
        settings.onboardingVersion = nil
        UserDefaults.standard.set(false, forKey: "studio.onboarding.v20.completed")
    }

    @discardableResult
    func addCrewMember(to projectID: UUID, name: String, role: String, email: String = "", phone: String = "") -> UUID? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let member = CrewMember(name: name, role: role, email: email, initials: initials.isEmpty ? "?" : initials, phone: phone.isEmpty ? nil : phone)
        projects[index].crew.append(member)
        pluginNotice = "Crew member added"
        return member.id
    }

    @discardableResult
    func addDevice(to projectID: UUID, name: String, category: String, quantity: Int = 1, serialNumber: String = "") -> UUID? {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let item = KitItem(name: name, category: category, packed: false, quantity: max(1, quantity), serialNumber: serialNumber.isEmpty ? nil : serialNumber)
        projects[index].kit.append(item)
        pluginNotice = "Device added"
        return item.id
    }

    func resetFeatureIntroductions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("studio.feature-intro.") {
            defaults.removeObject(forKey: key)
        }
        pluginNotice = "Feature introductions reset"
    }

    func resetToStarterWorkspace() {
        saveTask?.cancel()
        automaticBackupTask?.cancel()
        FramoV5Keychain.clearConnectionCredentials()
        settings = StudioSettings()
        projects = []
        tasks = []
        events = []
        spaces = []
        places = []
        invoices = []
        business = ModoBusinessState()
        seedPreviewData()
        selection = .home
        selectedProjectID = nil
        selectedSpaceID = nil
        duoProjectID = nil
        searchText = ""
        resetOnboarding()
        resetFeatureIntroductions()
        notificationState = FramoNotificationState()
        showNotificationCenter = false
        saveNow()
        pluginNotice = "MODO reset to the starter workspace"
    }

    func eraseAllWorkspaceData() {
        saveTask?.cancel()
        automaticBackupTask?.cancel()
        FramoV5Keychain.clearConnectionCredentials()
        removeAllManagedMedia()
        projects = []
        tasks = []
        events = []
        spaces = []
        places = []
        invoices = []
        business = ModoBusinessState()
        settings = StudioSettings()
        selection = .home
        selectedProjectID = nil
        selectedSpaceID = nil
        duoProjectID = nil
        searchText = ""
        resetOnboarding()
        resetFeatureIntroductions()
        notificationState = FramoNotificationState()
        showNotificationCenter = false
        saveNow()
        pluginNotice = "All workspace data erased"
    }

    func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else {
                Task { @MainActor in self.pluginNotice = "MODO couldn't restart automatically" }
                return
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func createPlace(name: String = "New place", address: String = "", latitude: Double = 50.8503, longitude: Double = 4.3517) -> UUID {
        let place = StudioPlace(name: name, address: address, notes: "", latitude: latitude, longitude: longitude)
        places.insert(place, at: 0)
        return place.id
    }

    func updatePlace(_ place: StudioPlace) {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index] = place
    }

    func deletePlace(_ id: UUID) {
        places.removeAll { $0.id == id }
        cleanupOrphanedManagedMedia()
    }

    func setPlaceLinked(_ placeID: UUID, to projectID: UUID, linked: Bool) {
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { return }
        var ids = places[index].projectIDs
        ids.removeAll { $0 == projectID }
        if linked { ids.append(projectID) }
        places[index].projectIDs = ids
    }

    func addPhoto(toPlace placeID: UUID, path: String) {
        addPhoto(toPlace: placeID, sourceURL: URL(fileURLWithPath: path))
    }

    func addPhoto(toPlace placeID: UUID, sourceURL: URL) {
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { return }
        guard let managed = importManagedImage(from: sourceURL, folder: "Places") else {
            pluginNotice = "MODO couldn't import that photo"
            return
        }
        if !places[index].photoPaths.contains(managed) { places[index].photoPaths.append(managed) }
    }

    func removePhoto(fromPlace placeID: UUID, path: String) {
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { return }
        places[index].photoPaths.removeAll { $0 == path }
        removeManagedFileIfOwned(path)
    }

    func setCrewPhoto(projectID: UUID, memberID: UUID, sourceURL: URL) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }),
              let cIndex = projects[pIndex].crew.firstIndex(where: { $0.id == memberID }),
              let managed = importManagedImage(from: sourceURL, folder: "Crew") else { return }
        let identity = crewIdentity(projects[pIndex].crew[cIndex])
        for projectIndex in projects.indices {
            for crewIndex in projects[projectIndex].crew.indices where crewIdentity(projects[projectIndex].crew[crewIndex]) == identity {
                projects[projectIndex].crew[crewIndex].photoPath = managed
            }
        }
        projectRefreshToken = UUID()
    }

    func setDevicePhoto(projectID: UUID, itemID: UUID, sourceURL: URL) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }),
              let kIndex = projects[pIndex].kit.firstIndex(where: { $0.id == itemID }),
              let managed = importManagedImage(from: sourceURL, folder: "Devices") else { return }
        projects[pIndex].kit[kIndex].photoPath = managed
        projectRefreshToken = UUID()
    }

    func assignCrewMember(_ member: CrewMember, toProject projectID: UUID) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let identity = crewIdentity(member)
        guard !projects[pIndex].crew.contains(where: { crewIdentity($0) == identity }) else { return }
        var copy = member
        copy.id = UUID()
        projects[pIndex].crew.append(copy)
        projectRefreshToken = UUID()
    }

    func removeCrewMember(_ member: CrewMember, fromProject projectID: UUID) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let identity = crewIdentity(member)
        projects[pIndex].crew.removeAll { crewIdentity($0) == identity }
        projectRefreshToken = UUID()
    }

    func removeCrewMemberEverywhere(_ member: CrewMember) {
        let identity = crewIdentity(member)
        for index in projects.indices { projects[index].crew.removeAll { crewIdentity($0) == identity } }
        cleanupOrphanedManagedMedia()
        projectRefreshToken = UUID()
    }

    func isCrewMember(_ member: CrewMember, assignedTo projectID: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        let identity = crewIdentity(member)
        return project.crew.contains { crewIdentity($0) == identity }
    }

    private func crewIdentity(_ member: CrewMember) -> String {
        let email = member.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty { return "email:\(email)" }
        return "name:\(member.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }


    // MARK: - Brand assets

    var brandAssets: [ModoBrandAsset] {
        settings.effectiveBrandAssets.sorted { $0.createdAt < $1.createdAt }
    }

    var primaryBrandLogo: ModoBrandAsset? {
        guard let id = settings.primaryBrandLogoID else { return nil }
        return brandAssets.first(where: { $0.id == id })
    }

    var primaryBrandIcon: ModoBrandAsset? {
        guard let id = settings.primaryBrandIconID else { return nil }
        return brandAssets.first(where: { $0.id == id })
    }

    @discardableResult
    func addBrandAsset(
        from sourceURL: URL,
        kind: ModoBrandAssetKind,
        name: String? = nil,
        makePrimary: Bool = false
    ) -> UUID? {
        guard let path = importManagedImageForWorkspace(from: sourceURL, category: "Brand Assets") else {
            return nil
        }

        let cleanName = (name ?? sourceURL.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = ModoBrandAsset(
            name: cleanName.isEmpty ? kind.rawValue : cleanName,
            kind: kind,
            path: path
        )

        var assets = settings.brandAssets ?? []
        assets.append(asset)
        settings.brandAssets = assets

        if makePrimary || (kind == .logo && settings.primaryBrandLogoID == nil) {
            settings.primaryBrandLogoID = asset.id
        }
        if makePrimary || (kind == .icon && settings.primaryBrandIconID == nil) {
            settings.primaryBrandIconID = asset.id
        }

        return asset.id
    }

    func setPrimaryBrandLogo(_ id: UUID?) {
        settings.primaryBrandLogoID = id
    }

    func setPrimaryBrandIcon(_ id: UUID?) {
        settings.primaryBrandIconID = id
    }

    func removeBrandAsset(_ id: UUID) {
        guard let asset = (settings.brandAssets ?? []).first(where: { $0.id == id }) else { return }

        settings.brandAssets?.removeAll { $0.id == id }
        if settings.primaryBrandLogoID == id { settings.primaryBrandLogoID = nil }
        if settings.primaryBrandIconID == id { settings.primaryBrandIconID = nil }

        removeManagedFileIfOwned(asset.path)
        cleanupOrphanedManagedMedia()
    }

    func setEnabledDestination(_ destination: SidebarDestination, enabled: Bool) {
        guard ![SidebarDestination.home, .search, .settings].contains(destination) else { return }

        var destinations = settings.effectiveEnabledDestinations
        if enabled {
            destinations.insert(destination)
        } else {
            destinations.remove(destination)
        }

        settings.enabledDestinations = SidebarDestination.allCases.filter { destinations.contains($0) }

        if !settings.effectiveVisibleDestinations.contains(selection) {
            openDestination(.home)
        }
    }

    func setEnabledDestinations(_ destinations: Set<SidebarDestination>) {
        var resolved = destinations
        resolved.insert(.home)
        resolved.insert(.search)
        resolved.insert(.settings)
        settings.enabledDestinations = SidebarDestination.allCases.filter { resolved.contains($0) }

        if !settings.effectiveVisibleDestinations.contains(selection) {
            openDestination(.home)
        }
    }

    /// Clears Peppol provider credentials without depending on a specific
    /// ModoPeppolConnector version. Older connector builds expose `disconnect()`
    /// but not the newer bulk `clearCredentials(profileIDs:)` helper.
    private func clearPeppolCredentials(profileIDs: [UUID]) {
        for profileID in profileIDs {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "be.modo.peppol.\(profileID.uuidString)",
                kSecAttrAccount as String: "peppyrus-api-key"
            ]
            SecItemDelete(query as CFDictionary)
        }

        peppolConnector.reloadForActiveProfile()
    }

    /// Resets the active workspace to a first-run content state while preserving
    /// the workspace container and its password/recovery credentials.
    func resetWorkspaceToOnboarding() {
        saveTask?.cancel()
        automaticBackupTask?.cancel()

        FramoV5Keychain.clearConnectionCredentials()
        if let profileID = activeProfileID {
            FramoV5Keychain.clearGoogleCredential(profileID: profileID)
            FramoV5Keychain.clearFrameIOCredential(profileID: profileID)
            FramoV5Keychain.clearMCPToken(profileID: profileID)
            clearPeppolCredentials(profileIDs: [profileID])
        }

        removeAllManagedMedia()

        projects = []
        tasks = []
        events = []
        spaces = []
        places = []
        invoices = []
        business = ModoBusinessState()
        notificationState = FramoNotificationState()
        settings = StudioSettings()

        selection = .home
        selectedProjectID = nil
        selectedSpaceID = nil
        duoProjectID = nil
        searchText = ""
        showNotificationCenter = false
        showGlobalSearch = false
        showTimeLauncher = false
        workspaceRecoveryNotice = nil

        resetFeatureIntroductions()
        resetOnboarding()
        saveNow()

        pluginNotice = "Workspace reset. Onboarding is ready."
    }

    /// Compatibility for older UI builds.
    func resetMODOToOnboarding() {
        resetWorkspaceToOnboarding()
    }

    /// Removes MODO's local profiles, local workspace data, app-scoped credentials
    /// and preferences. Portable workspaces on external drives are deliberately not
    /// deleted; they become disconnected and can be opened again later.
    func factoryResetMODO() {
        saveTask?.cancel()
        automaticBackupTask?.cancel()
        periodicBackupTask?.cancel()
        suspendProfileServices()

        let profileIDs = profiles.map(\.id)
        FramoV5Keychain.clearAllKnownCredentials(profileIDs: profileIDs)
        clearPeppolCredentials(profileIDs: profileIDs)

        if let activeProfileSecurityScopedURL {
            activeProfileSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.activeProfileSecurityScopedURL = nil
        }

        let root = Self.globalSupportRoot()
        try? FileManager.default.removeItem(at: root)

        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("studio.") || key.hasPrefix("framo.") || key.hasPrefix("modo.") {
            defaults.removeObject(forKey: key)
        }

        profiles = []
        activeProfileID = nil
        profileRootOverride = nil
        projects = []
        tasks = []
        events = []
        spaces = []
        places = []
        invoices = []
        business = ModoBusinessState()
        settings = StudioSettings()
        notificationState = FramoNotificationState()
        selection = .home
        selectedProjectID = nil
        selectedSpaceID = nil
        duoProjectID = nil
        backStack.removeAll()
        forwardStack.removeAll()
        searchText = ""
        showNotificationCenter = false
        showGlobalSearch = false
        showTimeLauncher = false

        loadProfileRegistry()
        _ = activateProfileRoot(for: activeProfileID)
        isLoading = false
        saveNow()
        isProfileLocked = activeProfile?.isPasswordProtected ?? false
        profileGatePresented = true
        pluginNotice = nil
    }

    private func managedMediaRoot() -> URL {
        // Managed assets belong to the active workspace. Portable profiles therefore
        // keep their references on the removable drive instead of leaking back into
        // this Mac's Application Support folder.
        workspaceSupportRoot().appendingPathComponent("Managed Media", isDirectory: true)
    }

    /// Copies a user-selected reference image into MODO-owned storage.
    /// Use this for lightweight assets that must survive deletion/moving of the original.
    /// Large production media should remain linked via security-scoped bookmarks.
    func importManagedImageForWorkspace(from sourceURL: URL, category: String) -> String? {
        importManagedImage(from: sourceURL, folder: category)
    }

    func revealManagedMedia() {
        let root = managedMediaRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func importManagedImage(from sourceURL: URL, folder: String) -> String? {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let directory = managedMediaRoot().appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension.lowercased()
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination.path
        } catch {
            pluginNotice = "Photo import failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func removeManagedFileIfOwned(_ path: String) {
        let root = managedMediaRoot().standardizedFileURL.path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes only MODO-owned files that are no longer referenced anywhere.
    /// External linked production media is never touched.
    func cleanupOrphanedManagedMedia() {
        let root = managedMediaRoot().standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let referenced = referencedManagedMediaPaths()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if !referenced.contains(url.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func referencedManagedMediaPaths() -> Set<String> {
        var paths = Set<String>()
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let root = managedMediaRoot().standardizedFileURL.path + "/"
            if standardized.hasPrefix(root) { paths.insert(standardized) }
        }

        for project in projects {
            add(project.bannerPath)
            project.storyboard.forEach { add($0.assetPath) }
            project.crew.forEach { add($0.photoPath) }
            project.kit.forEach { add($0.photoPath) }
        }
        spaces.forEach { add($0.bannerPath) }
        places.forEach { place in place.photoPaths.forEach { add($0) } }
        settings.effectiveBrandAssets.forEach { add($0.path) }
        return paths
    }

    private func removeAllManagedMedia() {
        try? FileManager.default.removeItem(at: managedMediaRoot())
    }

    private func mirrorManagedMediaBackup(into destinationRoot: URL) throws {
        let sourceRoot = managedMediaRoot()
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else { return }
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let source as URL in enumerator {
            let relative = String(source.path.dropFirst(sourceRoot.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let destination = destinationRoot.appendingPathComponent(relative)
            let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if sourceValues.isDirectory == true {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }

            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let destinationValues = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let unchanged = destinationValues?.fileSize == sourceValues.fileSize
                && destinationValues?.contentModificationDate == sourceValues.contentModificationDate
            if unchanged { continue }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func managedMediaBackupBesideWorkspace(_ workspaceURL: URL) -> URL? {
        let fm = FileManager.default
        let direct = workspaceURL.deletingLastPathComponent().appendingPathComponent("Managed Media", isDirectory: true)
        if fm.fileExists(atPath: direct.path) { return direct }

        let siblingOfAutomaticBackups = workspaceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Managed Media", isDirectory: true)
        if fm.fileExists(atPath: siblingOfAutomaticBackups.path) { return siblingOfAutomaticBackups }
        return nil
    }

    private func restoreManagedMediaBackup(from sourceRoot: URL) throws {
        let destinationRoot = managedMediaRoot()
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let source as URL in enumerator {
            let relative = String(source.path.dropFirst(sourceRoot.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            let destination = destinationRoot.appendingPathComponent(relative)
            let values = try source.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }

    private func rebaseManagedMediaReferencesToCurrentRoot() {
        let root = managedMediaRoot()
        let marker = "/Managed Media/"

        func rebased(_ path: String?) -> String? {
            guard let path, let range = path.range(of: marker, options: .backwards) else { return path }
            let suffix = String(path[range.upperBound...])
            let candidate = root.appendingPathComponent(suffix)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : path
        }

        for projectIndex in projects.indices {
            projects[projectIndex].bannerPath = rebased(projects[projectIndex].bannerPath)
            for storyboardIndex in projects[projectIndex].storyboard.indices {
                projects[projectIndex].storyboard[storyboardIndex].assetPath = rebased(projects[projectIndex].storyboard[storyboardIndex].assetPath)
            }
            for crewIndex in projects[projectIndex].crew.indices {
                projects[projectIndex].crew[crewIndex].photoPath = rebased(projects[projectIndex].crew[crewIndex].photoPath)
            }
            for kitIndex in projects[projectIndex].kit.indices {
                projects[projectIndex].kit[kitIndex].photoPath = rebased(projects[projectIndex].kit[kitIndex].photoPath)
            }
        }

        for index in spaces.indices { spaces[index].bannerPath = rebased(spaces[index].bannerPath) }
        for placeIndex in places.indices {
            places[placeIndex].photoPaths = places[placeIndex].photoPaths.map { rebased($0) ?? $0 }
        }

        if var assets = settings.brandAssets {
            for index in assets.indices {
                assets[index].path = rebased(assets[index].path) ?? assets[index].path
            }
            settings.brandAssets = assets
        }
    }

    private func repairWorkspaceRelationships() {
        let validProjectIDs = Set(projects.map(\.id))

        for index in spaces.indices {
            var seen = Set<UUID>()
            spaces[index].projectIDs = spaces[index].projectIDs.filter { validProjectIDs.contains($0) && seen.insert($0).inserted }
        }
        for index in places.indices {
            var seen = Set<UUID>()
            places[index].projectIDs = places[index].projectIDs.filter { validProjectIDs.contains($0) && seen.insert($0).inserted }
        }
        for index in tasks.indices where tasks[index].projectID.map({ !validProjectIDs.contains($0) }) == true {
            tasks[index].projectID = nil
        }
        for index in events.indices where events[index].projectID.map({ !validProjectIDs.contains($0) }) == true {
            events[index].projectID = nil
        }

        settings.pinnedProjectIDs = settings.pinnedProjectIDs?.filter { validProjectIDs.contains($0) }
        settings.fixedProjectTabIDs = settings.fixedProjectTabIDs?.filter { validProjectIDs.contains($0) }
        settings.sidebarProjectIDs = settings.sidebarProjectIDs?.filter { validProjectIDs.contains($0) }
    }

    func updateCrewMember(projectID: UUID, member: CrewMember) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }),
              let cIndex = projects[pIndex].crew.firstIndex(where: { $0.id == member.id }) else { return }
        projects[pIndex].crew[cIndex] = member
        projectRefreshToken = UUID()
    }

    func updateKitItem(projectID: UUID, item: KitItem) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }),
              let kIndex = projects[pIndex].kit.firstIndex(where: { $0.id == item.id }) else { return }
        projects[pIndex].kit[kIndex] = item
        projectRefreshToken = UUID()
    }

    func removeKitItem(projectID: UUID, itemID: UUID) {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[pIndex].kit.removeAll { $0.id == itemID }
        cleanupOrphanedManagedMedia()
        projectRefreshToken = UUID()
    }

    func createCrewMember(projectID: UUID, name: String = "New person", role: String = "Crew") {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        projects[index].crew.append(CrewMember(name: name, role: role, email: "", initials: initials.isEmpty ? "?" : initials))
        projectRefreshToken = UUID()
    }

    func createKitItem(projectID: UUID, name: String = "New item", category: String = "Gear") {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].kit.append(KitItem(name: name, category: category, packed: false, quantity: 1))
        projectRefreshToken = UUID()
    }

    struct ProjectStorageStat: Identifiable, Hashable {
        var id: UUID { projectID }
        let projectID: UUID
        let title: String
        let client: String
        let linkedBytes: Int64
        let linkedFiles: Int
        let tasks: Int
        let shots: Int
        let crew: Int
    }

    var projectStorageStats: [ProjectStorageStat] {
        projects.map { project in
            let files = project.linkedFiles ?? []
            return ProjectStorageStat(
                projectID: project.id,
                title: project.title,
                client: project.client,
                linkedBytes: files.reduce(Int64(0)) { $0 + $1.byteSize },
                linkedFiles: files.count,
                tasks: tasks.filter { $0.projectID == project.id }.count,
                shots: project.shots.count,
                crew: project.crew.count
            )
        }
        .sorted { $0.linkedBytes > $1.linkedBytes }
    }

    var linkedMediaBytes: Int64 {
        projects.reduce(Int64(0)) { partial, project in
            partial + (project.linkedFiles ?? []).reduce(Int64(0)) { $0 + $1.byteSize }
        }
    }

    var databaseByteSize: Int64 {
        (try? databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }

    func openMail(to email: String, subject: String = "") {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let escapedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:\(clean)?subject=\(escapedSubject)") { NSWorkspace.shared.open(url) }
    }

    func openMessage(phone: String) {
        let clean = phone.filter { $0.isNumber || $0 == "+" }
        guard !clean.isEmpty, let url = URL(string: "sms:\(clean)") else { return }
        NSWorkspace.shared.open(url)
    }

    func schedulePayload(_ payload: String, at date: Date) -> Bool {
        let value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("task:"), let id = UUID(uuidString: String(value.dropFirst(5))) {
            setTaskDueDate(id, date: date)
            return true
        }
        if value.hasPrefix("project:"), let id = UUID(uuidString: String(value.dropFirst(8))), let project = projects.first(where: { $0.id == id }) {
            createEvent(title: project.title, start: date, end: date.addingTimeInterval(3600), projectID: id, location: project.location)
            return true
        }
        if value.hasPrefix("place:"), let id = UUID(uuidString: String(value.dropFirst(6))), let place = places.first(where: { $0.id == id }) {
            createEvent(title: place.name, start: date, end: date.addingTimeInterval(3600), projectID: nil, location: place.address)
            return true
        }
        if let id = UUID(uuidString: value) {
            if tasks.contains(where: { $0.id == id }) { setTaskDueDate(id, date: date); return true }
            if let project = projects.first(where: { $0.id == id }) {
                createEvent(title: project.title, start: date, end: date.addingTimeInterval(3600), projectID: id, location: project.location)
                return true
            }
        }
        return false
    }
}


private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
