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

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoIDs.isEmpty }

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

    enum Parsed { case vault, entry(UUID), photo(UUID), unknown }
    static func parse(_ name: String) -> Parsed {
        if name == vault { return .vault }
        if name.hasPrefix("entry-"), let id = UUID(uuidString: String(name.dropFirst(6))) { return .entry(id) }
        if name.hasPrefix("photo-"), let id = UUID(uuidString: String(name.dropFirst(6))) { return .photo(id) }
        return .unknown
    }
}

enum DiaryFilter: Hashable {
    case all, starred, onThisDay, tag(String)
}

enum DiaryLayout: String, CaseIterable, Identifiable {
    case list = "List", calendar = "Calendar", media = "Media"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .calendar: "calendar"
        case .media: "photo.on.rectangle"
        }
    }
}
