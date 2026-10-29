import Foundation
import CloudKit

/// Everything on disk is either ciphertext or non-secret metadata. Decrypted text and images live only in memory.
///
///     Hushbook/vault.json          salt + wrapped diary key
///     Hushbook/entries/<id>.json   EntryEnvelope (sealed entry)
///     Hushbook/photos/<id>.bin     sealed JPEG
///     Hushbook/audio/<id>.bin      sealed M4A voice note
///     Hushbook/ck/<record>.sys     CloudKit system fields (change tags)
///     Hushbook/sync-state.json     CKSyncEngine state
final class LocalStore: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Hushbook", isDirectory: true)
        #if DEBUG
        if let demo = ProcessInfo.processInfo.environment["HUSHBOOK_DATA_DIR"] { dir = URL(fileURLWithPath: demo, isDirectory: true) }
        #endif
        root = dir
        for dir in ["entries", "photos", "audio", "ck"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: root.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true   // iCloud sync is the backup; keep ciphertext out of device backups too
        var url = root
        try? url.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) {
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // MARK: Vault

    private var vaultURL: URL { root.appendingPathComponent("vault.json") }

    func loadVault() -> VaultHeader? {
        locked { (try? Data(contentsOf: vaultURL)).flatMap { try? decoder.decode(VaultHeader.self, from: $0) } }
    }

    func saveVault(_ header: VaultHeader) {
        locked { write(try! encoder.encode(header), to: vaultURL) }
    }

    // MARK: Entries

    private func entryURL(_ id: UUID) -> URL { root.appendingPathComponent("entries/\(id.uuidString).json") }

    func envelope(_ id: UUID) -> EntryEnvelope? {
        locked { (try? Data(contentsOf: entryURL(id))).flatMap { try? decoder.decode(EntryEnvelope.self, from: $0) } }
    }

    func allEnvelopes() -> [UUID: EntryEnvelope] {
        locked {
            let dir = root.appendingPathComponent("entries")
            var result: [UUID: EntryEnvelope] = [:]
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let data = try? Data(contentsOf: url),
                      let env = try? decoder.decode(EntryEnvelope.self, from: data) else { continue }
                result[id] = env
            }
            return result
        }
    }

    func saveEnvelope(_ env: EntryEnvelope, id: UUID) {
        locked { write(try! encoder.encode(env), to: entryURL(id)) }
    }

    func deleteEntry(_ id: UUID) {
        locked { try? FileManager.default.removeItem(at: entryURL(id)) }
    }

    // MARK: Photos

    func photoURL(_ id: UUID) -> URL { root.appendingPathComponent("photos/\(id.uuidString).bin") }

    func sealedPhoto(_ id: UUID) -> Data? { locked { try? Data(contentsOf: photoURL(id)) } }

    func savePhoto(_ sealed: Data, id: UUID) { locked { write(sealed, to: photoURL(id)) } }

    func importPhoto(from url: URL, id: UUID) {
        locked {
            let dest = photoURL(id)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    func deletePhoto(_ id: UUID) { locked { try? FileManager.default.removeItem(at: photoURL(id)) } }

    func allPhotoIDs() -> [UUID] {
        locked {
            let dir = root.appendingPathComponent("photos")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) }
        }
    }

    // MARK: Voice notes

    func audioURL(_ id: UUID) -> URL { root.appendingPathComponent("audio/\(id.uuidString).bin") }

    func sealedAudio(_ id: UUID) -> Data? { locked { try? Data(contentsOf: audioURL(id)) } }

    func saveAudio(_ sealed: Data, id: UUID) { locked { write(sealed, to: audioURL(id)) } }

    func importAudio(from url: URL, id: UUID) {
        locked {
            let dest = audioURL(id)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }

    func deleteAudio(_ id: UUID) { locked { try? FileManager.default.removeItem(at: audioURL(id)) } }

    func allAudioIDs() -> [UUID] {
        locked {
            let dir = root.appendingPathComponent("audio")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) }
        }
    }

    // MARK: CloudKit metadata

    private func sysURL(_ name: String) -> URL { root.appendingPathComponent("ck/\(name).sys") }

    func systemFields(_ name: String) -> CKRecord? {
        locked {
            guard let data = try? Data(contentsOf: sysURL(name)),
                  let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            return CKRecord(coder: coder)
        }
    }

    func saveSystemFields(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        locked { write(coder.encodedData, to: sysURL(record.recordID.recordName)) }
    }

    func deleteSystemFields(_ name: String) { locked { try? FileManager.default.removeItem(at: sysURL(name)) } }

    func clearSystemFields() {
        locked {
            let dir = root.appendingPathComponent("ck")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Sync engine state

    private var stateURL: URL { root.appendingPathComponent("sync-state.json") }

    func loadSyncState() -> CKSyncEngine.State.Serialization? {
        locked { (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(CKSyncEngine.State.Serialization.self, from: $0) } }
    }

    func saveSyncState(_ state: CKSyncEngine.State.Serialization?) {
        locked {
            if let state, let data = try? encoder.encode(state) { write(data, to: stateURL) }
            else { try? FileManager.default.removeItem(at: stateURL) }
        }
    }

    /// Every record this device holds, for re-uploading after the iCloud zone was lost or the account changed.
    func allRecordNames() -> [String] {
        var names = allEnvelopes().keys.map(RecordName.entry) + allPhotoIDs().map(RecordName.photo)
            + allAudioIDs().map(RecordName.audio)
        if loadVault() != nil { names.append(RecordName.vault) }
        return names
    }
}
