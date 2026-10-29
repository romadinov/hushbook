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
    private(set) var importProgress: (done: Int, total: Int)?
    var importResult: String?

    var rememberDays: Int { didSet { UserDefaults.standard.set(rememberDays, forKey: "rememberDays") } }
    var autoLockSeconds: Int { didSet { UserDefaults.standard.set(autoLockSeconds, forKey: "autoLockSeconds") } }
    /// Remember where new entries are written.
    var addLocation: Bool { didSet { UserDefaults.standard.set(addLocation, forKey: "addLocation") } }
    var journalColor: JournalColor {
        didSet { UserDefaults.standard.set(journalColor.rawValue, forKey: "journalColor") }
    }
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
        journalColor = .current
        addLocation = defaults.object(forKey: "addLocation") as? Bool ?? true
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
        #if DEBUG
        if Self.demoMode != nil { sync.disabled = true; Task { await seedDemo() }; return }
        if ProcessInfo.processInfo.environment["HUSHBOOK_DATA_DIR"] != nil { sync.disabled = true; return }   // never sync a test folder
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
            // The remembered key must open this diary. A key for another diary (e.g. one created on this Mac by a
            // test run) would show an empty diary and seal new entries with the wrong key.
            guard opensDiary(key) else {
                BiometricUnlock.forget()
                return "\(BiometricUnlock.kindName) had a key that doesn't open this diary. Enter your password once to set it up again."
            }
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

    /// True if the key decrypts a few of the stored entries (or there are none yet to check).
    private func opensDiary(_ key: SymmetricKey) -> Bool {
        let sample = local.allEnvelopes().prefix(5)
        return sample.isEmpty || sample.contains { decrypt($0.value, id: $0.key, key: key) != nil }
    }

    private func didUnlock(_ key: SymmetricKey, fromPassword: Bool) {
        self.key = key
        // Only typing the password starts a new remember window; Face ID / Touch ID never extends it.
        // Debug runs on a test data folder never touch the Keychain: its item is shared with the real diary.
        if fromPassword && useBiometrics && !Self.usesTestFolder {
            BiometricUnlock.remember(key, until: Date.now.addingTimeInterval(Double(rememberDays) * 86_400))
        }
        reloadAll()
        phase = .unlocked
        Task { await sync.syncNow() }
    }

    /// Counts lock events, so the lock screen offers Face ID / Touch ID automatically once per lock.
    private(set) var lockCount = 0

    func lock() {
        guard phase == .unlocked else { return }
        lockCount += 1
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
        if useBiometrics && !Self.usesTestFolder {
            BiometricUnlock.remember(key, until: Date.now.addingTimeInterval(Double(rememberDays) * 86_400))
        }
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
        if let old {
            Set(old.photoIDs).subtracting(e.photoIDs).forEach(deletePhoto)
            Set(old.audio.map(\.id)).subtracting(e.audio.map(\.id)).forEach(deleteAudio)
        }
        upsert(e)
    }

    /// Drops a draft that never got content (or an entry that was emptied).
    func discardIfEmpty(_ id: UUID) {
        guard let entry = entry(id), entry.isEmpty else { return }
        if local.envelope(id) != nil { delete(entry) } else { entries.removeAll { $0.id == id } }
    }

    func delete(_ entry: Entry) {
        var photos = Set(entry.photoIDs)
        var audio = Set(entry.audio.map(\.id))
        if let key, let saved = local.envelope(entry.id).flatMap({ decrypt($0, id: entry.id, key: key) }) {
            photos.formUnion(saved.photoIDs)
            audio.formUnion(saved.audio.map(\.id))
        }
        local.deleteEntry(entry.id)
        sync.enqueueDelete(RecordName.entry(entry.id))
        photos.forEach(deletePhoto)
        audio.forEach(deleteAudio)
        entries.removeAll { $0.id == entry.id }
    }

    func toggleStar(_ entry: Entry) {
        var e = entry
        e.starred.toggle()
        save(e)
    }

    // MARK: Photos

    /// Encrypts and stores an image; returns its id for the entry's photo list.
    func addPhoto(_ data: Data, id: UUID = UUID()) async -> UUID? {
        guard let key else { return nil }
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

    // MARK: Voice notes

    /// Transcripts that finished while their entry was open in an editor; the editor folds them into its draft.
    private(set) var finishedTranscripts: [UUID: (text: String, language: String)] = [:]
    private(set) var transcribing: Set<UUID> = []
    @ObservationIgnored private var openEditors: [UUID: Int] = [:]

    /// Encrypts a recorded file, deletes the plaintext, and starts transcribing. Returns the note to add to the entry.
    func addVoiceNote(file: URL, duration: TimeInterval, entryID: UUID) async -> AudioNote? {
        guard let key else { try? FileManager.default.removeItem(at: file); return nil }
        let id = UUID()
        let result = await Task.detached { () -> (Data, [Float])? in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let sealed = try? DiaryCrypto.seal(data, key: key, id: RecordName.audio(id)) else { return nil }
            return (sealed, (try? AudioSamples.load16k(file)) ?? [])
        }.value
        guard let (sealed, samples) = result else { return nil }
        local.saveAudio(sealed, id: id)
        sync.enqueueSave(RecordName.audio(id))
        transcribe(samples, audio: id, entry: entryID)
        return AudioNote(id: id, duration: duration)
    }

    private func transcribe(_ samples: [Float], audio: UUID, entry: UUID) {
        transcribing.insert(audio)
        Task {
            let result = await Transcriber.shared.transcribe(samples)
            transcribing.remove(audio)
            guard key != nil else { return }   // locked meanwhile; the note stays untranscribed
            if openEditors[entry, default: 0] > 0 {
                finishedTranscripts[audio] = result
            } else if var e = self.entry(entry) {
                e.apply(transcript: result.text, to: audio)
                if let i = e.audio.firstIndex(where: { $0.id == audio }) { e.audio[i].language = result.language }
                save(e)
            }
        }
    }

    /// Re-runs transcription for a saved voice note (e.g. after the models were downloaded).
    func retranscribe(_ note: AudioNote, entry: UUID) {
        guard let key, !transcribing.contains(note.id) else { return }
        let local = self.local
        Task {
            let samples = await Task.detached { () -> [Float] in
                guard let sealed = local.sealedAudio(note.id),
                      let data = try? DiaryCrypto.open(sealed, key: key, id: RecordName.audio(note.id)) else { return [] }
                // AVAudioFile needs a file: decode from a temporary copy that is deleted immediately.
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: url) }
                guard (try? data.write(to: url)) != nil else { return [] }
                return (try? AudioSamples.load16k(url)) ?? []
            }.value
            if !samples.isEmpty { transcribe(samples, audio: note.id, entry: entry) }
        }
    }

    func takeTranscript(_ audio: UUID) -> (text: String, language: String)? {
        finishedTranscripts.removeValue(forKey: audio)
    }

    func editorOpened(_ entry: UUID) { openEditors[entry, default: 0] += 1 }

    /// After the editor saved its draft: apply transcripts it didn't get to.
    func editorClosed(_ entry: UUID) {
        openEditors[entry, default: 1] -= 1
        guard openEditors[entry, default: 0] <= 0, var e = self.entry(entry) else { return }
        var changed = false
        for note in e.audio {
            if let result = finishedTranscripts.removeValue(forKey: note.id) {
                e.apply(transcript: result.text, to: note.id)
                changed = true
            }
        }
        if changed { save(e) }
    }

    /// Decrypted voice note, in memory only, for playback.
    func audioData(_ id: UUID) async -> Data? {
        guard let key else { return nil }
        let local = self.local
        return await Task.detached {
            local.sealedAudio(id).flatMap { try? DiaryCrypto.open($0, key: key, id: RecordName.audio(id)) }
        }.value
    }

    func deleteAudio(_ id: UUID) {
        local.deleteAudio(id)
        sync.enqueueDelete(RecordName.audio(id))
    }

    // MARK: Day One import

    /// Imports an unzipped Day One JSON export. Entries already imported (same Day One id) are skipped.
    func importDayOne(folder: URL) async {
        guard key != nil else { return }
        let items: [DayOneImport.Item]
        do { items = try await Task.detached { try DayOneImport.read(folder: folder) }.value }
        catch { importResult = "Couldn't read the export: \(error.localizedDescription)"; return }
        guard !items.isEmpty else {
            importResult = "No Day One entries found. In Day One choose File → Export → JSON, then import that zip."
            return
        }
        var report = DayOneImport.Report()
        importProgress = (0, items.count)
        for (i, item) in items.enumerated() {
            importProgress = (i, items.count)
            guard key != nil else { break }   // locked mid-import
            if local.envelope(item.entry.id) != nil {
                // Imported before locations were supported: add the location, keep everything else.
                if let location = item.entry.location, var existing = entry(item.entry.id), existing.location == nil {
                    existing.location = location
                    save(existing)
                    report.locationsAdded += 1
                } else {
                    report.skipped += 1
                }
                continue
            }
            var entry = item.entry
            entry.photoIDs = []
            for photo in item.photos {
                guard let file = photo.file, let data = try? Data(contentsOf: file) else { report.missingPhotos += 1; continue }
                var stored = local.sealedPhoto(photo.id) != nil
                if !stored { stored = await addPhoto(data, id: photo.id) != nil }
                if stored {
                    entry.photoIDs.append(photo.id)
                    report.photos += 1
                }
            }
            guard !entry.isEmpty else { continue }
            persist(entry)
            report.imported += 1
        }
        importProgress = nil
        importResult = report.summary
    }

    /// Writes an entry as-is (keeping its original modification date), for imports.
    private func persist(_ e: Entry) {
        guard let key, let json = try? JSONEncoder().encode(e),
              let sealed = try? DiaryCrypto.seal(json, key: key, id: RecordName.entry(e.id)) else { return }
        local.saveEnvelope(EntryEnvelope(modified: e.modified, sealed: sealed), id: e.id)
        sync.enqueueSave(RecordName.entry(e.id))
        upsert(e)
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
    static var usesTestFolder: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["HUSHBOOK_DATA_DIR"] != nil
        #else
        false
        #endif
    }

    static var demoScreen: String? {
        #if DEBUG
        demoMode
        #else
        nil
        #endif
    }
}
