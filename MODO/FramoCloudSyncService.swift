import Foundation
import AppKit
import CloudKit
import CryptoKit
import Security

@MainActor
final class FramoCloudSyncService: ObservableObject {
    private enum CloudConfiguration {
        case ready(containerIdentifier: String)
        case unavailable(String)
    }

    private static let applicationIdentifierEntitlement = "com.apple.application-identifier"
    private static let teamIdentifierEntitlement = "com.apple.developer.team-identifier"
    private static let containerIdentifiersEntitlement = "com.apple.developer.icloud-container-identifiers"

    enum State: Equatable {
        case off
        case idle
        case syncing
        case success(Date)
        case unavailable(String)
        case failed(String)

        var label: String {
            switch self {
            case .off: return "Off"
            case .idle: return "Ready"
            case .syncing: return "Syncing…"
            case .success(let date): return "Synced \(date.formatted(date: .omitted, time: .shortened))"
            case .unavailable(let reason): return reason
            case .failed(let message): return message
            }
        }
    }

    struct Ledger: Codable {
        var entries: [String: LedgerEntry] = [:]
    }

    struct LedgerEntry: Codable {
        var localHash: String?
        var lastSyncedHash: String?
        var localModifiedAt: Date
        var cloudChangeTag: String?
        var deleted: Bool = false
        var lastSyncedDeleted: Bool = false
    }

    private struct Snapshot {
        let key: String
        let type: String
        let id: UUID
        let payload: Data
        let hash: String
    }

    private struct RemoteSnapshot {
        let record: CKRecord
        let key: String
        let type: String
        let id: UUID
        let payload: Data?
        let deleted: Bool
        let modifiedAt: Date
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastConflictCount = 0
    @Published private(set) var accountStatus = "Not checked"
    @Published private(set) var sharingStatus = "Private workspace"
    @Published private(set) var shareURL: URL?
    @Published private(set) var shareParticipantCount = 0

    private weak var store: FramoStudioStore?
    private var syncTask: Task<Void, Never>?
    private(set) var isApplyingRemote = false
    private(set) var isSyncing = false

    func install(store: FramoStudioStore) {
        self.store = store
        state = store.settings.effectiveCloudSyncEnabled ? .idle : .off
        ModoCloudShareBridge.handler = { [weak self] metadata in
            Task { @MainActor [weak self] in await self?.acceptIncomingShare(metadata) }
        }
        Task {
            await refreshAccountStatus()
            await refreshSharingStatus()
        }
    }

    func refreshForActiveProfile() {
        syncTask?.cancel()
        lastConflictCount = 0
        lastSyncDate = nil
        shareURL = nil
        shareParticipantCount = 0
        state = store?.settings.effectiveCloudSyncEnabled == true ? .idle : .off
        Task {
            await refreshAccountStatus()
            await refreshSharingStatus()
        }
    }

    func setEnabled(_ enabled: Bool) {
        store?.settings.cloudSyncEnabled = enabled
        state = enabled ? .idle : .off
        if enabled { scheduleSync(delay: 0.2) }
    }

    func scheduleSync(delay: TimeInterval = 1.4) {
        guard let store,
              store.settings.effectiveCloudSyncEnabled,
              store.settings.effectiveCloudAutoSyncEnabled,
              !store.profileGatePresented,
              !isApplyingRemote else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard delay > 0 else { await self?.syncNow(); return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let store, store.settings.effectiveCloudSyncEnabled else {
            state = .off
            return
        }
        guard !store.profileGatePresented else { return }
        guard !isSyncing else { return }
        guard let profileID = store.activeProfileID else {
            state = .failed("No active workspace")
            return
        }

        isSyncing = true
        state = .syncing
        defer { isSyncing = false }

        do {
            guard case .ready(let containerIdentifier) = Self.cloudConfiguration() else {
                let reason = Self.cloudConfigurationMessage()
                accountStatus = reason
                state = .unavailable(reason)
                return
            }
            let container = CKContainer(identifier: containerIdentifier)
            let account = try await container.accountStatus()
            guard account == .available else {
                accountStatus = Self.accountLabel(account)
                state = .unavailable(accountStatus)
                return
            }
            accountStatus = "iCloud available"
            let target = cloudTarget(container: container, profileID: profileID)
            let database = target.database
            let zoneID = target.zoneID
            if !target.isSharedParticipant {
                try await ensureZone(zoneID, database: database)
            }

            var ledger = loadLedger()
            let local = try localSnapshots(store: store)
            updateLedgerForLocalChanges(local, ledger: &ledger)
            let remote = try await fetchRemoteSnapshots(database: database, zoneID: zoneID)

            let localByKey = Dictionary(uniqueKeysWithValues: local.map { ($0.key, $0) })
            let remoteByKey = Dictionary(uniqueKeysWithValues: remote.map { ($0.key, $0) })
            for remoteItem in remote where ledger.entries[remoteItem.key] == nil {
                ledger.entries[remoteItem.key] = LedgerEntry(localHash: nil, lastSyncedHash: nil, localModifiedAt: .distantPast)
            }
            let allKeys = Set(localByKey.keys).union(remoteByKey.keys).union(ledger.entries.keys)
            var conflicts = 0
            var projectsToApply: [UUID: StudioProject?] = [:]
            var tasksToApply: [UUID: StudioTask?] = [:]
            var eventsToApply: [UUID: StudioEvent?] = [:]
            var spacesToApply: [UUID: StudioSpace?] = [:]
            var placesToApply: [UUID: StudioPlace?] = [:]
            var invoicesToApply: [UUID: ModoInvoice?] = [:]
            var organizationsToApply: [UUID: ModoOrganization?] = [:]
            var peopleToApply: [UUID: ModoPerson?] = [:]
            var opportunitiesToApply: [UUID: ModoOpportunity?] = [:]
            var quotesToApply: [UUID: ModoQuote?] = [:]
            var paymentsToApply: [UUID: ModoPayment?] = [:]
            var activitiesToApply: [UUID: ModoActivityEntry?] = [:]

            for key in allKeys.sorted() {
                guard var entry = ledger.entries[key] else { continue }
                let localSnapshot = localByKey[key]
                let remoteSnapshot = remoteByKey[key]
                let localDeleted = localSnapshot == nil && entry.deleted
                let localChanged = (localSnapshot?.hash != entry.lastSyncedHash) || (localDeleted != entry.lastSyncedDeleted)
                let remoteChanged = remoteSnapshot?.record.recordChangeTag != entry.cloudChangeTag

                if let remoteSnapshot, localChanged && remoteChanged {
                    conflicts += 1
                    if entry.localModifiedAt >= remoteSnapshot.modifiedAt {
                        let saved = try await upload(local: localSnapshot, tombstoneKey: key, entry: entry, database: database, zoneID: zoneID)
                        entry.cloudChangeTag = saved.recordChangeTag
                        entry.lastSyncedHash = localSnapshot?.hash
                        entry.lastSyncedDeleted = localSnapshot == nil
                    } else {
                        try apply(remoteSnapshot, projects: &projectsToApply, tasks: &tasksToApply, events: &eventsToApply, spaces: &spacesToApply, places: &placesToApply, invoices: &invoicesToApply, organizations: &organizationsToApply, people: &peopleToApply, opportunities: &opportunitiesToApply, quotes: &quotesToApply, payments: &paymentsToApply, activities: &activitiesToApply)
                        entry.localHash = remoteSnapshot.payload.map(Self.hash)
                        entry.lastSyncedHash = entry.localHash
                        entry.deleted = remoteSnapshot.deleted
                        entry.lastSyncedDeleted = remoteSnapshot.deleted
                        entry.localModifiedAt = remoteSnapshot.modifiedAt
                        entry.cloudChangeTag = remoteSnapshot.record.recordChangeTag
                    }
                } else if localChanged {
                    let saved = try await upload(local: localSnapshot, tombstoneKey: key, entry: entry, database: database, zoneID: zoneID)
                    entry.cloudChangeTag = saved.recordChangeTag
                    entry.lastSyncedHash = localSnapshot?.hash
                    entry.lastSyncedDeleted = localSnapshot == nil
                } else if let remoteSnapshot, remoteChanged {
                    try apply(remoteSnapshot, projects: &projectsToApply, tasks: &tasksToApply, events: &eventsToApply, spaces: &spacesToApply, places: &placesToApply, invoices: &invoicesToApply, organizations: &organizationsToApply, people: &peopleToApply, opportunities: &opportunitiesToApply, quotes: &quotesToApply, payments: &paymentsToApply, activities: &activitiesToApply)
                    entry.localHash = remoteSnapshot.payload.map(Self.hash)
                    entry.lastSyncedHash = entry.localHash
                    entry.deleted = remoteSnapshot.deleted
                    entry.lastSyncedDeleted = remoteSnapshot.deleted
                    entry.localModifiedAt = remoteSnapshot.modifiedAt
                    entry.cloudChangeTag = remoteSnapshot.record.recordChangeTag
                } else if entry.cloudChangeTag == nil, let remoteSnapshot {
                    entry.cloudChangeTag = remoteSnapshot.record.recordChangeTag
                    entry.lastSyncedHash = localSnapshot?.hash
                    entry.lastSyncedDeleted = remoteSnapshot.deleted
                }
                ledger.entries[key] = entry
            }

            if !projectsToApply.isEmpty || !tasksToApply.isEmpty || !eventsToApply.isEmpty || !spacesToApply.isEmpty || !placesToApply.isEmpty || !invoicesToApply.isEmpty || !organizationsToApply.isEmpty || !peopleToApply.isEmpty || !opportunitiesToApply.isEmpty || !quotesToApply.isEmpty || !paymentsToApply.isEmpty || !activitiesToApply.isEmpty {
                isApplyingRemote = true
                applyRemoteChanges(projectsToApply, tasks: tasksToApply, events: eventsToApply, spaces: spacesToApply, places: placesToApply, invoices: invoicesToApply, organizations: organizationsToApply, people: peopleToApply, opportunities: opportunitiesToApply, quotes: quotesToApply, payments: paymentsToApply, activities: activitiesToApply, store: store)
                isApplyingRemote = false
            }

            saveLedger(ledger)
            lastConflictCount = conflicts
            lastSyncDate = .now
            state = .success(.now)
        } catch {
            isApplyingRemote = false
            state = .failed(error.localizedDescription)
        }
    }

    func refreshAccountStatus() async {
        switch Self.cloudConfiguration() {
        case .unavailable(let reason):
            accountStatus = reason
            if store?.settings.effectiveCloudSyncEnabled == true {
                state = .unavailable(reason)
            }
            return
        case .ready(let containerIdentifier):
            do {
                let status = try await CKContainer(identifier: containerIdentifier).accountStatus()
                accountStatus = Self.accountLabel(status)
                if store?.settings.effectiveCloudSyncEnabled == true, status != .available {
                    state = .unavailable(accountStatus)
                }
            } catch {
                accountStatus = error.localizedDescription
                if store?.settings.effectiveCloudSyncEnabled == true {
                    state = .unavailable(accountStatus)
                }
            }
        }
    }

    func refreshSharingStatus() async {
        guard let store, let profileID = store.activeProfileID else {
            sharingStatus = "No active workspace"
            shareURL = nil
            shareParticipantCount = 0
            return
        }
        guard case .ready(let containerIdentifier) = Self.cloudConfiguration() else {
            sharingStatus = "Cloud sharing unavailable"
            shareURL = nil
            shareParticipantCount = 0
            return
        }
        let container = CKContainer(identifier: containerIdentifier)
        if store.settings.hasSharedCloudWorkspace,
           let zoneName = store.settings.cloudSharedZoneName,
           let ownerName = store.settings.cloudSharedZoneOwnerName {
            sharingStatus = "Shared with you"
            shareURL = store.settings.cloudShareURL.flatMap(URL.init(string:))
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            if let share = try? await fetchZoneShare(database: container.sharedCloudDatabase, zoneID: zoneID) {
                shareParticipantCount = share.participants.count
                shareURL = share.url ?? shareURL
            }
            return
        }

        let zoneID = CKRecordZone.ID(zoneName: "FRAMO-\(profileID.uuidString)", ownerName: CKCurrentUserDefaultName)
        if let share = try? await fetchZoneShare(database: container.privateCloudDatabase, zoneID: zoneID) {
            shareURL = share.url
            shareParticipantCount = share.participants.count
            sharingStatus = share.participants.count > 1 ? "Shared · \(share.participants.count) people" : "Share ready"
            if let url = share.url?.absoluteString, store.settings.cloudShareURL != url {
                store.settings.cloudShareURL = url
            }
        } else {
            shareURL = store.settings.cloudShareURL.flatMap(URL.init(string:))
            shareParticipantCount = 0
            sharingStatus = "Private workspace"
        }
    }

    @discardableResult
    func createWorkspaceShare() async throws -> URL {
        guard let store, let profileID = store.activeProfileID else { throw CloudShareError.noWorkspace }
        guard !store.settings.hasSharedCloudWorkspace else { throw CloudShareError.participantCannotReshare }
        guard case .ready(let containerIdentifier) = Self.cloudConfiguration() else { throw CloudShareError.cloudUnavailable }
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else { throw CloudShareError.cloudUnavailable }
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "FRAMO-\(profileID.uuidString)", ownerName: CKCurrentUserDefaultName)
        try await ensureZone(zoneID, database: database)
        if store.settings.effectiveCloudSyncEnabled { await syncNow() }
        let share = try await getOrCreateZoneShare(container: container, database: database, zoneID: zoneID)
        guard let url = share.url else { throw CloudShareError.missingShareURL }
        store.settings.cloudShareURL = url.absoluteString
        store.settings.cloudSharePermission = "owner"
        shareURL = url
        shareParticipantCount = share.participants.count
        sharingStatus = share.participants.count > 1 ? "Shared · \(share.participants.count) people" : "Share ready"
        return url
    }

    func invite(email: String, readOnly: Bool = false) async throws -> URL {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.contains("@") else { throw CloudShareError.invalidEmail }
        guard let store, let profileID = store.activeProfileID else { throw CloudShareError.noWorkspace }
        guard !store.settings.hasSharedCloudWorkspace else { throw CloudShareError.participantCannotReshare }
        guard case .ready(let containerIdentifier) = Self.cloudConfiguration() else { throw CloudShareError.cloudUnavailable }
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "FRAMO-\(profileID.uuidString)", ownerName: CKCurrentUserDefaultName)
        try await ensureZone(zoneID, database: database)
        let share = try await getOrCreateZoneShare(container: container, database: database, zoneID: zoneID)
        var participant = try await container.shareParticipant(forEmailAddress: clean)
        participant.permission = readOnly ? .readOnly : .readWrite
        share.addParticipant(participant)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = store.activeProfileName as CKRecordValue
        let saved = try await database.save(share)
        guard let savedShare = saved as? CKShare, let url = savedShare.url else { throw CloudShareError.missingShareURL }
        store.settings.cloudShareURL = url.absoluteString
        store.settings.cloudSharePermission = "owner"
        shareURL = url
        shareParticipantCount = savedShare.participants.count
        sharingStatus = "Shared · \(savedShare.participants.count) people"
        return url
    }

    func copyShareLink() async {
        do {
            let url: URL
            if let existingShareURL = shareURL {
                url = existingShareURL
            } else {
                url = try await createWorkspaceShare()
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            store?.pluginNotice = "MODO workspace share link copied"
        } catch {
            store?.pluginNotice = error.localizedDescription
        }
    }

    func acceptShareURL(_ url: URL) async {
        guard case .ready(let containerIdentifier) = Self.cloudConfiguration() else {
            store?.pluginNotice = CloudShareError.cloudUnavailable.localizedDescription
            return
        }
        do {
            let container = CKContainer(identifier: containerIdentifier)
            let metadata = try await container.shareMetadata(for: url)
            await acceptIncomingShare(metadata)
        } catch {
            store?.pluginNotice = error.localizedDescription
        }
    }

    func acceptIncomingShare(_ metadata: CKShare.Metadata) async {
        guard let store else { return }
        do {
            let container = CKContainer(identifier: metadata.containerIdentifier)
            let share = try await container.accept(metadata)
            let zoneID = share.recordID.zoneID
            store.settings.cloudSharedZoneName = zoneID.zoneName
            store.settings.cloudSharedZoneOwnerName = zoneID.ownerName
            store.settings.cloudShareURL = share.url?.absoluteString
            store.settings.cloudSharePermission = Self.permissionLabel(metadata.participantPermission)
            store.settings.cloudSyncEnabled = true
            store.settings.cloudAutoSyncEnabled = true
            shareURL = share.url
            shareParticipantCount = share.participants.count
            sharingStatus = "Shared with you"
            state = .idle
            saveLedger(Ledger())
            await syncNow()
            store.pluginNotice = "Shared MODO workspace connected"
        } catch {
            store.pluginNotice = "Could not accept shared workspace: \(error.localizedDescription)"
        }
    }

    func leaveSharedWorkspace() async {
        guard let store, store.settings.hasSharedCloudWorkspace,
              let zoneName = store.settings.cloudSharedZoneName,
              let ownerName = store.settings.cloudSharedZoneOwnerName,
              case .ready(let containerIdentifier) = Self.cloudConfiguration() else { return }
        let container = CKContainer(identifier: containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        if let share = try? await fetchZoneShare(database: container.sharedCloudDatabase, zoneID: zoneID) {
            _ = try? await container.sharedCloudDatabase.deleteRecord(withID: share.recordID)
        }
        clearSharedWorkspaceSettings(store: store)
        saveLedger(Ledger())
        state = store.settings.effectiveCloudSyncEnabled ? .idle : .off
        sharingStatus = "Private workspace"
        shareURL = nil
        shareParticipantCount = 0
        store.pluginNotice = "Disconnected from shared iCloud workspace"
    }

    func stopSharingOwnedWorkspace() async {
        guard let store, let profileID = store.activeProfileID,
              case .ready(let containerIdentifier) = Self.cloudConfiguration() else { return }
        let container = CKContainer(identifier: containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: "FRAMO-\(profileID.uuidString)", ownerName: CKCurrentUserDefaultName)
        if let share = try? await fetchZoneShare(database: container.privateCloudDatabase, zoneID: zoneID) {
            _ = try? await container.privateCloudDatabase.deleteRecord(withID: share.recordID)
        }
        store.settings.cloudShareURL = nil
        store.settings.cloudSharePermission = nil
        shareURL = nil
        shareParticipantCount = 0
        sharingStatus = "Private workspace"
        store.pluginNotice = "Workspace sharing stopped"
    }

    private func cloudTarget(container: CKContainer, profileID: UUID) -> (database: CKDatabase, zoneID: CKRecordZone.ID, isSharedParticipant: Bool) {
        if let store, store.settings.hasSharedCloudWorkspace,
           let zoneName = store.settings.cloudSharedZoneName,
           let ownerName = store.settings.cloudSharedZoneOwnerName {
            return (container.sharedCloudDatabase, CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName), true)
        }
        return (
            container.privateCloudDatabase,
            CKRecordZone.ID(zoneName: "FRAMO-\(profileID.uuidString)", ownerName: CKCurrentUserDefaultName),
            false
        )
    }

    private func getOrCreateZoneShare(container: CKContainer, database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare {
        if let existing = try? await fetchZoneShare(database: database, zoneID: zoneID) { return existing }
        guard let store else { throw CloudShareError.noWorkspace }
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = store.activeProfileName as CKRecordValue
        let saved = try await database.save(share)
        guard let result = saved as? CKShare else { throw CloudShareError.invalidShare }
        return result
    }

    private func fetchZoneShare(database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let record = try await database.record(for: shareID)
        guard let share = record as? CKShare else { throw CloudShareError.invalidShare }
        return share
    }

    private func clearSharedWorkspaceSettings(store: FramoStudioStore) {
        store.settings.cloudSharedZoneName = nil
        store.settings.cloudSharedZoneOwnerName = nil
        store.settings.cloudShareURL = nil
        store.settings.cloudSharePermission = nil
    }

    private static func permissionLabel(_ permission: CKShare.ParticipantPermission) -> String {
        switch permission {
        case .readOnly: return "read-only"
        case .readWrite: return "read-write"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }

    enum CloudShareError: LocalizedError {
        case noWorkspace, cloudUnavailable, invalidEmail, missingShareURL, invalidShare, participantCannotReshare
        var errorDescription: String? {
            switch self {
            case .noWorkspace: return "Open a MODO workspace first."
            case .cloudUnavailable: return "CloudKit sharing is not available in this signed build."
            case .invalidEmail: return "Enter a valid iCloud email address."
            case .missingShareURL: return "CloudKit did not return a share link."
            case .invalidShare: return "CloudKit returned an invalid workspace share."
            case .participantCannotReshare: return "Only the owner can invite people to this workspace."
            }
        }
    }

    private func localSnapshots(store: FramoStudioStore) throws -> [Snapshot] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var output: [Snapshot] = []
        for item in store.projects {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "project:\(item.id.uuidString)", type: "project", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.tasks {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "task:\(item.id.uuidString)", type: "task", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.events {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "event:\(item.id.uuidString)", type: "event", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.spaces {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "space:\(item.id.uuidString)", type: "space", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.places {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "place:\(item.id.uuidString)", type: "place", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.invoices {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "invoice:\(item.id.uuidString)", type: "invoice", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.business.organizations {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "organization:\(item.id.uuidString)", type: "organization", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.business.people {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "person:\(item.id.uuidString)", type: "person", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.business.opportunities {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "opportunity:\(item.id.uuidString)", type: "opportunity", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.business.quotes {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "quote:\(item.id.uuidString)", type: "quote", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.business.payments {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "payment:\(item.id.uuidString)", type: "payment", id: item.id, payload: data, hash: Self.hash(data)))
        }
        for item in store.business.activities {
            let data = try encoder.encode(item)
            output.append(Snapshot(key: "activity:\(item.id.uuidString)", type: "activity", id: item.id, payload: data, hash: Self.hash(data)))
        }
        return output
    }

    private func updateLedgerForLocalChanges(_ local: [Snapshot], ledger: inout Ledger) {
        let current = Dictionary(uniqueKeysWithValues: local.map { ($0.key, $0) })
        for snapshot in local {
            if var entry = ledger.entries[snapshot.key] {
                if entry.localHash != snapshot.hash || entry.deleted {
                    entry.localHash = snapshot.hash
                    entry.localModifiedAt = .now
                    entry.deleted = false
                    ledger.entries[snapshot.key] = entry
                }
            } else {
                ledger.entries[snapshot.key] = LedgerEntry(localHash: snapshot.hash, lastSyncedHash: nil, localModifiedAt: .now)
            }
        }
        for key in ledger.entries.keys where current[key] == nil {
            guard var entry = ledger.entries[key], !entry.deleted else { continue }
            entry.localHash = nil
            entry.localModifiedAt = .now
            entry.deleted = true
            ledger.entries[key] = entry
        }
    }

    private func ensureZone(_ zoneID: CKRecordZone.ID, database: CKDatabase) async throws {
        do { _ = try await database.recordZone(for: zoneID) }
        catch {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }

    private func fetchRemoteSnapshots(database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> [RemoteSnapshot] {
        var records: [CKRecord] = []
        for recordType in ["FRAMOProject", "FRAMOTask", "FRAMOEvent", "FRAMOSpace", "FRAMOPlace", "MODOInvoice", "MODOOrganization", "MODOPerson", "MODOOpportunity", "MODOQuote", "MODOPayment", "MODOActivity"] {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            var page = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                desiredKeys: nil,
                resultsLimit: CKQueryOperation.maximumResults
            )
            records.append(contentsOf: page.matchResults.compactMap { try? $0.1.get() })
            while let cursor = page.queryCursor {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: nil,
                    resultsLimit: CKQueryOperation.maximumResults
                )
                records.append(contentsOf: page.matchResults.compactMap { try? $0.1.get() })
            }
        }
        return records.compactMap { record in
            guard let key = record["entityKey"] as? String,
                  let type = record["entityType"] as? String,
                  let rawID = record["entityID"] as? String,
                  let id = UUID(uuidString: rawID) else { return nil }
            return RemoteSnapshot(
                record: record,
                key: key,
                type: type,
                id: id,
                payload: record["payload"] as? Data,
                deleted: (record["deleted"] as? NSNumber)?.boolValue ?? false,
                modifiedAt: (record["modifiedAt"] as? Date) ?? record.modificationDate ?? .distantPast
            )
        }
    }

    private func upload(local: Snapshot?, tombstoneKey: String, entry: LedgerEntry, database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKRecord {
        let parts = tombstoneKey.split(separator: ":", maxSplits: 1).map(String.init)
        let type = local?.type ?? parts.first ?? "entity"
        let id = local?.id.uuidString ?? (parts.count > 1 ? parts[1] : UUID().uuidString)
        let recordType: String
        switch type {
        case "project": recordType = "FRAMOProject"
        case "task": recordType = "FRAMOTask"
        case "event": recordType = "FRAMOEvent"
        case "space": recordType = "FRAMOSpace"
        case "place": recordType = "FRAMOPlace"
        case "invoice": recordType = "MODOInvoice"
        case "organization": recordType = "MODOOrganization"
        case "person": recordType = "MODOPerson"
        case "opportunity": recordType = "MODOOpportunity"
        case "quote": recordType = "MODOQuote"
        case "payment": recordType = "MODOPayment"
        case "activity": recordType = "MODOActivity"
        default: recordType = "FRAMOEntity"
        }
        let recordID = CKRecord.ID(recordName: tombstoneKey.replacingOccurrences(of: ":", with: "-"), zoneID: zoneID)
        let record: CKRecord
        if let existing = try? await database.record(for: recordID) { record = existing }
        else { record = CKRecord(recordType: recordType, recordID: recordID) }
        record["entityKey"] = tombstoneKey as CKRecordValue
        record["entityType"] = type as CKRecordValue
        record["entityID"] = id as CKRecordValue
        record["modifiedAt"] = entry.localModifiedAt as CKRecordValue
        record["deleted"] = NSNumber(value: local == nil)
        if let payload = local?.payload { record["payload"] = payload as CKRecordValue }
        else { record["payload"] = nil }
        return try await database.save(record)
    }

    private func apply(
        _ remote: RemoteSnapshot,
        projects: inout [UUID: StudioProject?],
        tasks: inout [UUID: StudioTask?],
        events: inout [UUID: StudioEvent?],
        spaces: inout [UUID: StudioSpace?],
        places: inout [UUID: StudioPlace?],
        invoices: inout [UUID: ModoInvoice?],
        organizations: inout [UUID: ModoOrganization?],
        people: inout [UUID: ModoPerson?],
        opportunities: inout [UUID: ModoOpportunity?],
        quotes: inout [UUID: ModoQuote?],
        payments: inout [UUID: ModoPayment?],
        activities: inout [UUID: ModoActivityEntry?]
    ) throws {
        if remote.deleted {
            switch remote.type {
            case "project": projects[remote.id] = nil
            case "task": tasks[remote.id] = nil
            case "event": events[remote.id] = nil
            case "space": spaces[remote.id] = nil
            case "place": places[remote.id] = nil
            case "invoice": invoices[remote.id] = nil
            case "organization": organizations[remote.id] = nil
            case "person": people[remote.id] = nil
            case "opportunity": opportunities[remote.id] = nil
            case "quote": quotes[remote.id] = nil
            case "payment": payments[remote.id] = nil
            case "activity": activities[remote.id] = nil
            default: break
            }
            return
        }
        guard let payload = remote.payload else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        switch remote.type {
        case "project": projects[remote.id] = try decoder.decode(StudioProject.self, from: payload)
        case "task": tasks[remote.id] = try decoder.decode(StudioTask.self, from: payload)
        case "event": events[remote.id] = try decoder.decode(StudioEvent.self, from: payload)
        case "space": spaces[remote.id] = try decoder.decode(StudioSpace.self, from: payload)
        case "place": places[remote.id] = try decoder.decode(StudioPlace.self, from: payload)
        case "invoice": invoices[remote.id] = try decoder.decode(ModoInvoice.self, from: payload)
        case "organization": organizations[remote.id] = try decoder.decode(ModoOrganization.self, from: payload)
        case "person": people[remote.id] = try decoder.decode(ModoPerson.self, from: payload)
        case "opportunity": opportunities[remote.id] = try decoder.decode(ModoOpportunity.self, from: payload)
        case "quote": quotes[remote.id] = try decoder.decode(ModoQuote.self, from: payload)
        case "payment": payments[remote.id] = try decoder.decode(ModoPayment.self, from: payload)
        case "activity": activities[remote.id] = try decoder.decode(ModoActivityEntry.self, from: payload)
        default: break
        }
    }

    private func applyRemoteChanges(
        _ projectChanges: [UUID: StudioProject?],
        tasks taskChanges: [UUID: StudioTask?],
        events eventChanges: [UUID: StudioEvent?],
        spaces spaceChanges: [UUID: StudioSpace?],
        places placeChanges: [UUID: StudioPlace?],
        invoices invoiceChanges: [UUID: ModoInvoice?],
        organizations organizationChanges: [UUID: ModoOrganization?],
        people peopleChanges: [UUID: ModoPerson?],
        opportunities opportunityChanges: [UUID: ModoOpportunity?],
        quotes quoteChanges: [UUID: ModoQuote?],
        payments paymentChanges: [UUID: ModoPayment?],
        activities activityChanges: [UUID: ModoActivityEntry?],
        store: FramoStudioStore
    ) {
        var projects = store.projects
        var tasks = store.tasks
        var events = store.events
        var spaces = store.spaces
        var places = store.places
        var invoices = store.invoices
        var business = store.business
        for (id, value) in projectChanges {
            projects.removeAll { $0.id == id }
            if let value { projects.append(value) }
        }
        for (id, value) in taskChanges {
            tasks.removeAll { $0.id == id }
            if let value { tasks.append(value) }
        }
        for (id, value) in eventChanges {
            events.removeAll { $0.id == id }
            if let value { events.append(value) }
        }
        for (id, value) in spaceChanges {
            spaces.removeAll { $0.id == id }
            if let value { spaces.append(value) }
        }
        for (id, value) in placeChanges {
            places.removeAll { $0.id == id }
            if let value { places.append(value) }
        }
        for (id, value) in invoiceChanges {
            invoices.removeAll { $0.id == id }
            if let value { invoices.append(value) }
        }
        for (id, value) in organizationChanges {
            business.organizations.removeAll { $0.id == id }
            if let value { business.organizations.append(value) }
        }
        for (id, value) in peopleChanges {
            business.people.removeAll { $0.id == id }
            if let value { business.people.append(value) }
        }
        for (id, value) in opportunityChanges {
            business.opportunities.removeAll { $0.id == id }
            if let value { business.opportunities.append(value) }
        }
        for (id, value) in quoteChanges {
            business.quotes.removeAll { $0.id == id }
            if let value { business.quotes.append(value) }
        }
        for (id, value) in paymentChanges {
            business.payments.removeAll { $0.id == id }
            if let value { business.payments.append(value) }
        }
        for (id, value) in activityChanges {
            business.activities.removeAll { $0.id == id }
            if let value { business.activities.append(value) }
        }
        business.organizations.sort { $0.updatedAt > $1.updatedAt }
        business.opportunities.sort { $0.updatedAt > $1.updatedAt }
        business.quotes.sort { $0.updatedAt > $1.updatedAt }
        business.payments.sort { $0.date > $1.date }
        business.activities.sort { $0.date > $1.date }
        projects.sort { $0.createdAt > $1.createdAt }
        invoices.sort { $0.updatedAt > $1.updatedAt }
        store.applyCloudCollections(projects: projects, tasks: tasks, events: events, spaces: spaces, places: places, invoices: invoices, business: business)
    }

    private var ledgerURL: URL? { store?.workspaceRootURL.appendingPathComponent("cloud-sync-ledger.json") }

    private func loadLedger() -> Ledger {
        guard let ledgerURL, let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    private func saveLedger(_ ledger: Ledger) {
        guard let ledgerURL, let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: [.atomic])
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    private static func cloudConfiguration() -> CloudConfiguration {
        let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundleIdentifier.isEmpty else {
            return .unavailable("CloudKit unavailable: this build has no bundle identifier.")
        }

        guard let applicationIdentifier = signedEntitlement(applicationIdentifierEntitlement) as? String,
              isValidApplicationIdentifier(applicationIdentifier, bundleIdentifier: bundleIdentifier) else {
            return .unavailable(
                "CloudKit unavailable: this build is not signed with a valid Apple Developer Team. " +
                "Choose a Team in Xcode → Signing & Capabilities, then rebuild."
            )
        }

        guard let teamIdentifier = signedEntitlement(teamIdentifierEntitlement) as? String,
              isValidTeamIdentifier(teamIdentifier),
              applicationIdentifier.hasPrefix(teamIdentifier + ".") else {
            return .unavailable(
                "CloudKit unavailable: the signed Team ID is missing or invalid. " +
                "Check Xcode → Signing & Capabilities."
            )
        }

        guard let identifiers = signedEntitlement(containerIdentifiersEntitlement) as? [String],
              !identifiers.isEmpty else {
            return .unavailable(
                "CloudKit unavailable: no iCloud container is present in the signed entitlements. " +
                "Add iCloud → CloudKit in Xcode and select a container."
            )
        }

        let expectedIdentifier = "iCloud.\(bundleIdentifier)"
        let usable = identifiers.filter { identifier in
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasPrefix("iCloud.") &&
                   !value.contains("$(") &&
                   !value.contains("${") &&
                   value.count > "iCloud.".count
        }

        guard !usable.isEmpty else {
            return .unavailable(
                "CloudKit unavailable: the iCloud container entitlement did not resolve to a real container identifier."
            )
        }

        let selected = usable.first(where: { $0 == expectedIdentifier }) ?? usable[0]
        return .ready(containerIdentifier: selected)
    }

    private static func cloudConfigurationMessage() -> String {
        switch cloudConfiguration() {
        case .ready:
            return "iCloud available"
        case .unavailable(let reason):
            return reason
        }
    }

    private static func isValidApplicationIdentifier(_ value: String, bundleIdentifier: String) -> Bool {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, isValidTeamIdentifier(parts[0]) else { return false }
        return parts[1] == bundleIdentifier
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
        }
    }

    private static func accountLabel(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "iCloud available"
        case .noAccount: return "Sign in to iCloud on this Mac"
        case .restricted: return "iCloud is restricted on this Mac"
        case .couldNotDetermine: return "Couldn’t determine iCloud status"
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable"
        @unknown default: return "iCloud unavailable"
        }
    }
}
