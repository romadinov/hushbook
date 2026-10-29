import Foundation

struct Entry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()          // the day the entry is about; editable
    var text = ""
    var tags: [String] = []
    var photoIDs: [UUID] = []
    var starred = false
    var created = Date()
    var modified = Date()
    /// Optional so entries saved before voice notes existed still decode.
    var audioNotes: [AudioNote]?
    var location: EntryLocation?

    var audio: [AudioNote] {
        get { audioNotes ?? [] }
        set { audioNotes = newValue.isEmpty ? nil : newValue }
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoIDs.isEmpty && audio.isEmpty
    }

    /// Stores a finished transcript on its voice note and adds it to the entry text.
    mutating func apply(transcript: String, to audioID: UUID) {
        guard let i = audio.firstIndex(where: { $0.id == audioID }), audio[i].transcript == nil else { return }
        audio[i].transcript = transcript
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = body.isEmpty ? t : body + "\n" + t
    }

    /// First non-empty line, as Day One shows it.
    var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    var preview: String {
        let lines = text.split(whereSeparator: \.isNewline).dropFirst()
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return text.localizedCaseInsensitiveContains(q) || tags.contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

struct AudioNote: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var duration: Double
    var recorded = Date()
    /// Nil while transcribing; "" when nothing was recognised.
    var transcript: String?
    var language: String?
}

/// A note written without unlocking, as sealed into the drop box. Becomes an entry at the next unlock.
struct QuickNote: Codable, Sendable {
    struct Photo: Codable, Sendable {
        var id = UUID()
        var jpeg: Data
    }
    var id = UUID()
    var date = Date()
    var text: String
    var photos: [Photo]
    var location: EntryLocation?
}

/// What is stored on disk and in iCloud for an entry: the sealed JSON plus a plaintext modification time used to
/// resolve edit conflicts without the key (CloudKit records its own modification times anyway).
struct EntryEnvelope: Codable, Sendable {
    var modified: Date
    var sealed: Data
}

enum RecordName {
    static let vault = "vault"
    static func entry(_ id: UUID) -> String { "entry-\(id.uuidString)" }
    static func photo(_ id: UUID) -> String { "photo-\(id.uuidString)" }
    static func audio(_ id: UUID) -> String { "audio-\(id.uuidString)" }
    static func quickNote(_ id: UUID) -> String { "quicknote-\(id.uuidString)" }   // never synced; only seals

    enum Parsed { case vault, entry(UUID), photo(UUID), audio(UUID), unknown }
    static func parse(_ name: String) -> Parsed {
        if name == vault { return .vault }
        if name.hasPrefix("entry-"), let id = UUID(uuidString: String(name.dropFirst(6))) { return .entry(id) }
        if name.hasPrefix("photo-"), let id = UUID(uuidString: String(name.dropFirst(6))) { return .photo(id) }
        if name.hasPrefix("audio-"), let id = UUID(uuidString: String(name.dropFirst(6))) { return .audio(id) }
        return .unknown
    }
}

enum DiaryFilter: Hashable {
    case all, starred, onThisDay, tag(String)
}

enum DiaryLayout: String, CaseIterable, Identifiable {
    case list = "List", calendar = "Calendar", media = "Media", map = "Map"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .calendar: "calendar"
        case .media: "photo.on.rectangle"
        case .map: "map"
        }
    }
}
