import Foundation
import CloudKit
import os

struct SyncChanges: Sendable {
    var entries: Set<UUID> = []
    var deletedEntries: Set<UUID> = []
    var photos: Set<UUID> = []
    var vault = false
    var isEmpty: Bool { entries.isEmpty && deletedEntries.isEmpty && photos.isEmpty && !vault }
}

/// iCloud sync via CKSyncEngine. Works entirely on ciphertext, so it keeps syncing while the diary is locked.
/// Records (zone "Diary" in the private database):
///   Vault  "vault"          salt, iterations, wrappedKey
///   Entry  "entry-<uuid>"   payload (sealed JSON), modified
///   Photo  "photo-<uuid>"   asset (sealed JPEG)
///   Audio  "audio-<uuid>"   asset (sealed M4A)
final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    static let containerID = "iCloud.com.romadinov.hushbook"
    let zoneID = CKRecordZone.ID(zoneName: "Diary", ownerName: CKCurrentUserDefaultName)

    private let store: LocalStore
    private let log = Logger(subsystem: "com.romadinov.hushbook", category: "sync")
    private var _engine: CKSyncEngine?
    private let engineLock = NSLock()

    /// Called (on an arbitrary thread) after remote changes were written to the local store.
    var onChange: (@Sendable (SyncChanges) -> Void)?
    var onActivity: (@Sendable (_ busy: Bool, _ error: String?) -> Void)?

    init(store: LocalStore) { self.store = store }

    var engine: CKSyncEngine {
        engineLock.lock(); defer { engineLock.unlock() }
        if let _engine { return _engine }
        let state = store.loadSyncState()
        let config = CKSyncEngine.Configuration(database: CKContainer(identifier: Self.containerID).privateCloudDatabase,
                                                stateSerialization: state, delegate: self)
        let engine = CKSyncEngine(config)
        _engine = engine
        if state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        return engine
    }

    func start() { _ = engine }

    /// Demo diaries never touch iCloud.
    var disabled = false

    func enqueueSave(_ name: String) {
        guard !disabled else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
    }

    func enqueueDelete(_ name: String) {
        guard !disabled else { return }
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID))])
    }

    func fetch() async throws { try await engine.fetchChanges() }

    func syncNow() async {
        guard !disabled else { return }
        onActivity?(true, nil)
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            onActivity?(false, nil)
        } catch {
            onActivity?(false, error.localizedDescription)
        }
    }

    private func reuploadEverything() {
        store.clearSystemFields()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(pendingRecordZoneChanges: store.allRecordNames().map {
            .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
        })
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            store.saveSyncState(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts: reuploadEverything()
            case .signOut: store.clearSystemFields()
            @unknown default: break
            }

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                log.notice("Diary zone was deleted in iCloud; re-uploading this device's copy")
                reuploadEverything()
            }

        case .fetchedRecordZoneChanges(let changes):
            var result = SyncChanges()
            for mod in changes.modifications { apply(mod.record, into: &result) }
            for deletion in changes.deletions {
                let name = deletion.recordID.recordName
                store.deleteSystemFields(name)
                switch RecordName.parse(name) {
                case .entry(let id): store.deleteEntry(id); result.deletedEntries.insert(id)
                case .photo(let id): store.deletePhoto(id)
                case .audio(let id): store.deleteAudio(id)
                default: break
                }
            }
            if !result.isEmpty { onChange?(result) }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords { store.saveSystemFields(record) }
            for name in sent.deletedRecordIDs.map(\.recordName) { store.deleteSystemFields(name) }
            var result = SyncChanges()
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    guard let server = failure.error.serverRecord else { break }
                    if localWins(over: server) {
                        store.saveSystemFields(server)   // adopt the new change tag, then send ours again
                        retry.append(.saveRecord(id))
                    } else {
                        apply(server, into: &result)
                    }
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    store.deleteSystemFields(id.recordName)
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    store.deleteSystemFields(id.recordName)
                    retry.append(.saveRecord(id))
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                     .operationCancelled, .requestRateLimited:
                    break   // CKSyncEngine retries these itself
                default:
                    log.error("Saving \(id.recordName) failed: \(failure.error.localizedDescription)")
                }
            }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            if !result.isEmpty { onChange?(result) }

        case .willFetchChanges, .willSendChanges:
            onActivity?(true, nil)
        case .didFetchChanges, .didSendChanges:
            onActivity?(false, nil)
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [self] recordID in
            if let record = makeRecord(recordID) { return record }
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])   // gone locally
            return nil
        }
    }

    // MARK: Records

    private func makeRecord(_ id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        func record(_ type: String) -> CKRecord { store.systemFields(name) ?? CKRecord(recordType: type, recordID: id) }
        switch RecordName.parse(name) {
        case .vault:
            guard let header = store.loadVault() else { return nil }
            let r = record("Vault")
            r["version"] = header.version
            r["salt"] = header.salt
            r["iterations"] = header.iterations
            r["wrappedKey"] = header.wrappedKey
            return r
        case .entry(let uuid):
            guard let env = store.envelope(uuid) else { return nil }
            let r = record("Entry")
            r["payload"] = env.sealed
            r["modified"] = env.modified
            return r
        case .photo(let uuid):
            let url = store.photoURL(uuid)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let r = record("Photo")
            r["asset"] = CKAsset(fileURL: url)
            return r
        case .audio(let uuid):
            let url = store.audioURL(uuid)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let r = record("Audio")
            r["asset"] = CKAsset(fileURL: url)
            return r
        case .unknown:
            return nil
        }
    }

    private func localWins(over server: CKRecord) -> Bool {
        guard case .entry(let id) = RecordName.parse(server.recordID.recordName),
              let local = store.envelope(id) else { return false }
        let remote = server["modified"] as? Date ?? .distantPast
        return local.modified > remote
    }

    private func apply(_ record: CKRecord, into result: inout SyncChanges) {
        switch RecordName.parse(record.recordID.recordName) {
        case .vault:
            guard let salt = record["salt"] as? Data, let wrapped = record["wrappedKey"] as? Data,
                  let iterations = record["iterations"] as? Int else { return }
            let header = VaultHeader(version: record["version"] as? Int ?? 1, salt: salt, iterations: iterations, wrappedKey: wrapped)
            if store.loadVault() != header { store.saveVault(header); result.vault = true }
        case .entry(let id):
            guard let sealed = record["payload"] as? Data else { return }
            let modified = record["modified"] as? Date ?? .distantPast
            if let local = store.envelope(id), local.modified > modified {
                enqueueSave(record.recordID.recordName)   // ours is newer; it will overwrite
            } else {
                store.saveEnvelope(EntryEnvelope(modified: modified, sealed: sealed), id: id)
                result.entries.insert(id)
            }
        case .photo(let id):
            guard let url = (record["asset"] as? CKAsset)?.fileURL else { return }
            store.importPhoto(from: url, id: id)
            result.photos.insert(id)
        case .audio(let id):
            guard let url = (record["asset"] as? CKAsset)?.fileURL else { return }
            store.importAudio(from: url, id: id)
        case .unknown:
            return
        }
        store.saveSystemFields(record)
    }
}
