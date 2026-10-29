import SwiftUI
import CryptoKit
import CloudKit
import Observation

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

@MainActor @Observable
final class DiaryStore {
    enum Phase { case checkingCloud, needsSetup, locked, unlocked }

    private(set) var phase: Phase
    private(set) var entries: [Entry] = []      // newest first; includes unsaved drafts
    private(set) var unreadableCount = 0
    private(set) var photoRevision = 0          // bumped when photos arrive from iCloud
    private(set) var syncBusy = false
    private(set) var syncError: String?
    private(set) var lastSync: Date?

    var rememberDays: Int { didSet { UserDefaults.standard.set(rememberDays, forKey: "rememberDays") } }
    var autoLockSeconds: Int { didSet { UserDefaults.standard.set(autoLockSeconds, forKey: "autoLockSeconds") } }
    var useBiometrics: Bool {
        didSet {
            UserDefaults.standard.set(useBiometrics, forKey: "useBiometrics")
            if !useBiometrics { BiometricUnlock.forget() }
        }
    }

    @ObservationIgnored let local = LocalStore()
    @ObservationIgnored let sync: CloudSync
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private let imageCache = NSCache<NSString, ImageBox>()
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundedAt: Date?

    init() {
        let defaults = UserDefaults.standard
        #if os(iOS)
        let defaultAutoLock = 0
        #else
        let defaultAutoLock = 300
        #endif
        rememberDays = defaults.object(forKey: "rememberDays") as? Int ?? 7
        autoLockSeconds = defaults.object(forKey: "autoLockSeconds") as? Int ?? defaultAutoLock
        useBiometrics = defaults.object(forKey: "useBiometrics") as? Bool ?? true
        sync = CloudSync(store: local)
        phase = local.loadVault() == nil ? .checkingCloud : .locked
        imageCache.countLimit = 400

        sync.onChange = { [weak self] changes in Task { @MainActor in self?.applyRemote(changes) } }
        sync.onActivity = { [weak self] busy, error in
            Task { @MainActor in
                guard let self else { return }
                self.syncBusy = busy
                if let error { self.syncError = error } else if !busy { self.syncError = nil; self.lastSync = .now }
            }
        }
        #if targetEnvironment(simulator)
        if Self.demoMode != nil { Task { await seedDemo() }; return }
        #endif
        sync.start()
        if phase == .checkingCloud { Task { await lookForExistingDiary() } }
    }

    // MARK: Setup and unlocking

    /// A second device must adopt the diary created on the first, so look in iCloud before offering to create one.
    func lookForExistingDiary() async {
        phase = .checkingCloud
        let container = CKContainer(identifier: CloudSync.containerID)
        if (try? await container.accountStatus()) == .available {
            let sync = self.sync
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await sync.fetch() }
                group.addTask { try? await Task.sleep(for: .seconds(25)) }
                await group.next()
                group.cancelAll()
            }
        }
        phase = local.loadVault() == nil ? .needsSetup : .locked
    }

    func createDiary(password: String) async {
        guard let (header, key) = await Task.detached(operation: { try? DiaryCrypto.createVault(password: password) }).value
        else { return }
        local.saveVault(header)
        sync.enqueueSave(RecordName.vault)
        didUnlock(key, fromPassword: true)
    }

    /// Returns false for a wrong password.
    func unlock(password: String) async -> Bool {
        guard let header = local.loadVault() else { return false }
        guard let key = await Task.detached(operation: { DiaryCrypto.unwrap(header, password: password) }).value
        else { return false }
        didUnlock(key, fromPassword: true)
        return true
    }

    var canUseBiometrics: Bool { useBiometrics && BiometricUnlock.canUnlock }

    /// Returns a message to show, or nil (unlocked, cancelled, or the person chose to type the password).
    func unlockWithBiometrics() async -> String? {
        switch await BiometricUnlock.unlock(reason: "Unlock your diary") {
        case .success(let key):
            didUnlock(key, fromPassword: false)
            return nil
        case .failure(.expired):
            return "It's been \(rememberDays) day\(rememberDays == 1 ? "" : "s"). Enter your diary password."
        case .failure(.unavailable(let message)):
            return message
        case .failure:
            return nil
        }
    }

    private func didUnlock(_ key: SymmetricKey, fromPassword: Bool) {
        self.key = key
        // Only typing the password starts a new remember window; Face ID / Touch ID never extends it.
        if fromPassword && useBiometrics {
            BiometricUnlock.remember(key, until: Date.now.addingTimeInterval(Double(rememberDays) * 86_400))
        }
        reloadAll()
        phase = .unlocked
        Task { await sync.syncNow() }
    }

    func lock() {
        guard phase == .unlocked else { return }
        lockTask?.cancel()
        key = nil
        entries = []
        imageCache.removeAllObjects()
        phase = .locked
    }

    /// Forget the remembered key so the password is needed next time, then lock.
    func lockAndRequirePassword() {
        BiometricUnlock.forget()
        lock()
    }

    func changePassword(current: String, new: String) async -> Bool {
        guard let header = local.loadVault(), let key,
              let check = await Task.detached(operation: { DiaryCrypto.unwrap(header, password: current) }).value,
              check.rawData == key.rawData,
              let newHeader = await Task.detached(operation: { try? DiaryCrypto.wrap(key, password: new) }).value
        else { return false }
        local.saveVault(newHeader)
        sync.enqueueSave(RecordName.vault)
        if useBiometrics { BiometricUnlock.remember(key, until: Date.now.addingTimeInterval(Double(rememberDays) * 86_400)) }
        return true
    }

    // MARK: Auto-lock

    func didEnterBackground() {
        guard phase == .unlocked else { return }
        backgroundedAt = .now
        if autoLockSeconds == 0 { lock(); return }
        lockTask?.cancel()
        let delay = autoLockSeconds
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    func didBecomeActive() {
        lockTask?.cancel()
        if let at = backgroundedAt, Date.now.timeIntervalSince(at) >= Double(autoLockSeconds) { lock() }
        backgroundedAt = nil
        if phase == .unlocked { Task { await sync.syncNow() } }
    }

    // MARK: Entries

    private func decrypt(_ env: EntryEnvelope, id: UUID, key: SymmetricKey) -> Entry? {
        guard let json = try? DiaryCrypto.open(env.sealed, key: key, id: RecordName.entry(id)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: json)
    }

    private func reloadAll() {
        guard let key else { return }
        var list: [Entry] = []
        var bad = 0
        for (id, env) in local.allEnvelopes() {
            if let entry = decrypt(env, id: id, key: key) { list.append(entry) } else { bad += 1 }
        }
        entries = list.sorted { $0.date > $1.date }
        unreadableCount = bad
    }

    private func applyRemote(_ changes: SyncChanges) {
        if changes.vault, phase == .checkingCloud || phase == .needsSetup { phase = .locked }
        if !changes.photos.isEmpty { photoRevision += 1 }
        guard let key, phase == .unlocked else { return }
        entries.removeAll { changes.deletedEntries.contains($0.id) }
        for id in changes.entries {
            guard let env = local.envelope(id), let entry = decrypt(env, id: id, key: key) else { continue }
            upsert(entry)
        }
    }

    private func upsert(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry } else { entries.append(entry) }
        entries.sort { $0.date > $1.date }
    }

    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    /// A new entry, listed immediately but only written once it has content.
    func newDraft(date: Date = .now, photoIDs: [UUID] = []) -> Entry {
        let entry = Entry(date: date, photoIDs: photoIDs)
        upsert(entry)
        if !photoIDs.isEmpty { save(entry) }
        return entry
    }

    func save(_ entry: Entry) {
        guard let key else { return }
        let old = local.envelope(entry.id).flatMap { decrypt($0, id: entry.id, key: key) }
        if entry.isEmpty {
            if old != nil { delete(entry) } else { upsert(entry) }
            return
        }
        if let old, old == entry { return }
        var e = entry
        e.modified = .now
        guard let json = try? JSONEncoder().encode(e),
              let sealed = try? DiaryCrypto.seal(json, key: key, id: RecordName.entry(e.id)) else { return }
        local.saveEnvelope(EntryEnvelope(modified: e.modified, sealed: sealed), id: e.id)
        sync.enqueueSave(RecordName.entry(e.id))
        if let old { Set(old.photoIDs).subtracting(e.photoIDs).forEach(deletePhoto) }
        upsert(e)
    }

    /// Drops a draft that never got content (or an entry that was emptied).
    func discardIfEmpty(_ id: UUID) {
        guard let entry = entry(id), entry.isEmpty else { return }
        if local.envelope(id) != nil { delete(entry) } else { entries.removeAll { $0.id == id } }
    }

    func delete(_ entry: Entry) {
        var photos = Set(entry.photoIDs)
        if let key, let saved = local.envelope(entry.id).flatMap({ decrypt($0, id: entry.id, key: key) }) {
            photos.formUnion(saved.photoIDs)
        }
        local.deleteEntry(entry.id)
        sync.enqueueDelete(RecordName.entry(entry.id))
        photos.forEach(deletePhoto)
        entries.removeAll { $0.id == entry.id }
    }

    func toggleStar(_ entry: Entry) {
        var e = entry
        e.starred.toggle()
        save(e)
    }

    // MARK: Photos

    /// Encrypts and stores an image; returns its id for the entry's photo list.
    func addPhoto(_ data: Data) async -> UUID? {
        guard let key else { return nil }
        let id = UUID()
        let sealed = await Task.detached { () -> Data? in
            guard let jpeg = Images.normalized(data) else { return nil }
            return try? DiaryCrypto.seal(jpeg, key: key, id: RecordName.photo(id))
        }.value
        guard let sealed else { return nil }
        local.savePhoto(sealed, id: id)
        sync.enqueueSave(RecordName.photo(id))
        return id
    }

    func deletePhoto(_ id: UUID) {
        local.deletePhoto(id)
        sync.enqueueDelete(RecordName.photo(id))
    }

    /// Decrypted, downscaled image, kept only in memory. Nil until the photo has synced to this device.
    func image(_ id: UUID, maxPixel: Int) async -> CGImage? {
        let cacheKey = "\(id.uuidString)-\(maxPixel)" as NSString
        if let hit = imageCache.object(forKey: cacheKey) { return hit.image }
        guard let key else { return nil }
        let local = self.local
        let box = await Task.detached { () -> ImageBox? in
            guard let sealed = local.sealedPhoto(id),
                  let jpeg = try? DiaryCrypto.open(sealed, key: key, id: RecordName.photo(id)),
                  let image = Images.cgImage(jpeg, maxPixel: maxPixel) else { return nil }
            return ImageBox(image)
        }.value
        guard let box, self.key != nil else { return nil }
        imageCache.setObject(box, forKey: cacheKey)
        return box.image
    }

    // MARK: Queries

    var saved: [Entry] { entries.filter { !$0.isEmpty } }

    func entries(_ filter: DiaryFilter, search: String = "") -> [Entry] {
        let cal = Calendar.current
        let today = cal.dateComponents([.month, .day, .year], from: .now)
        return entries.filter { e in
            guard e.matches(search) else { return false }
            switch filter {
            case .all: return true
            case .starred: return e.starred
            case .tag(let tag): return e.tags.contains(tag)
            case .onThisDay:
                let c = cal.dateComponents([.month, .day, .year], from: e.date)
                return c.month == today.month && c.day == today.day && c.year != today.year
            }
        }
    }

    var allTags: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { for t in e.tags { counts[t, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var stats: (entries: Int, days: Int, photos: Int) {
        let list = saved
        let days = Set(list.map { Calendar.current.startOfDay(for: $0.date) }).count
        return (list.count, days, list.reduce(0) { $0 + $1.photoIDs.count })
    }

    func syncNow() { Task { await sync.syncNow() } }
}

extension DiaryStore {
    static var demoScreen: String? {
        #if targetEnvironment(simulator)
        demoMode
        #else
        nil
        #endif
    }
}
