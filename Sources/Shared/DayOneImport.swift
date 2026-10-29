import Foundation
import CryptoKit

/// Reads a Day One JSON export (File → Export → JSON in Day One): one `<Journal>.json` per journal with an
/// `entries` array, and a `photos/` folder whose files are named `<md5>.<type>`. Entry text references photos as
/// `![](dayone-moment://<identifier>)`. Ids are derived from Day One's, so importing again skips what's already here.
enum DayOneImport {
    struct Photo { let id: UUID; let file: URL? }
    struct Item { let entry: Entry; let photos: [Photo] }

    struct Report {
        var imported = 0, skipped = 0, photos = 0, missingPhotos = 0, locationsAdded = 0
        var summary: String {
            var s = "Imported \(imported) entr\(imported == 1 ? "y" : "ies") and \(photos) photo\(photos == 1 ? "" : "s")."
            if skipped > 0 { s += " \(skipped) were already in Hushbook." }
            if locationsAdded > 0 { s += " Added locations to \(locationsAdded) earlier imports." }
            if missingPhotos > 0 { s += " \(missingPhotos) photo\(missingPhotos == 1 ? "" : "s") weren't in the export." }
            return s
        }
    }

    /// Every journal JSON under `folder` (an unzipped export), with its entries.
    static func read(folder: URL) throws -> [Item] {
        let fm = FileManager.default
        let jsons = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
        var items: [Item] = []
        for json in jsons {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
                  let entries = root["entries"] as? [[String: Any]] else { continue }
            let photoDir = json.deletingLastPathComponent().appendingPathComponent("photos")
            let photoFiles = (try? fm.contentsOfDirectory(at: photoDir, includingPropertiesForKeys: nil)) ?? []
            let byMD5 = Dictionary(photoFiles.map { ($0.deletingPathExtension().lastPathComponent.lowercased(), $0) },
                                   uniquingKeysWith: { a, _ in a })
            for raw in entries { if let item = item(raw, photos: byMD5) { items.append(item) } }
        }
        return items
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        if let d = iso.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }

    private static func item(_ raw: [String: Any], photos byMD5: [String: URL]) -> Item? {
        guard let uuid = raw["uuid"] as? String, let created = date(raw["creationDate"]) else { return nil }
        let photos = ((raw["photos"] as? [[String: Any]]) ?? [])
            .sorted { ($0["orderInEntry"] as? Int ?? 0) < ($1["orderInEntry"] as? Int ?? 0) }
            .compactMap { p -> Photo? in
                guard let identifier = p["identifier"] as? String ?? p["md5"] as? String else { return nil }
                let md5 = (p["md5"] as? String)?.lowercased() ?? ""
                return Photo(id: stableID(identifier, salt: "photo"), file: byMD5[md5])
            }
        var entry = Entry()
        entry.id = stableID(uuid, salt: "entry")
        entry.date = created
        entry.created = created
        entry.modified = date(raw["modifiedDate"]) ?? created
        entry.text = cleanText(raw["text"] as? String ?? "")
        entry.tags = (raw["tags"] as? [String]) ?? []
        entry.starred = raw["starred"] as? Bool ?? false
        entry.photoIDs = photos.map(\.id)
        entry.location = location(raw["location"] as? [String: Any])
        return Item(entry: entry, photos: photos)
    }

    private static func location(_ raw: [String: Any]?) -> EntryLocation? {
        guard let raw, let lat = (raw["latitude"] as? NSNumber)?.doubleValue, let lon = (raw["longitude"] as? NSNumber)?.doubleValue
        else { return nil }
        let locality = [raw["localityName"] as? String, raw["administrativeArea"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return EntryLocation(latitude: lat, longitude: lon, name: raw["placeName"] as? String,
                             locality: locality.isEmpty ? nil : locality, country: raw["country"] as? String)
    }

    /// Day One stores Markdown with escaped punctuation and inline media links; Hushbook keeps plain text.
    static func cleanText(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"!\[[^\]]*\]\(dayone-moment:[^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\([!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
        var lines = s.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines[i] = lines[i].replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            lines.removeFirst(i)
        }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Day One ids are 32 hex digits; use them directly as UUIDs when possible.
    static func stableID(_ dayOneID: String, salt: String) -> UUID {
        let hex = dayOneID.filter(\.isHexDigit)
        if hex.count == 32 {
            let c = Array(hex)
            let s = String(c[0..<8]) + "-" + String(c[8..<12]) + "-" + String(c[12..<16]) + "-" + String(c[16..<20]) + "-" + String(c[20..<32])
            if let id = UUID(uuidString: s) { return id }
        }
        let d = Array(SHA256.hash(data: Data("\(salt):\(dayOneID)".utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}
