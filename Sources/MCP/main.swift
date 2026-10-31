import Foundation
import AVFoundation

// hushbook-mcp: a write-only Model Context Protocol server for Hushbook (stdio, newline-delimited JSON-RPC 2.0).
//
// Its one tool seals a journal note into the drop box (see DropBox, Inbox), exactly like Quick Hashnote: it needs
// only the drop box public key, works while the diary is locked, and has no way to read the diary. The note becomes
// an entry when Hushbook is next unlocked (or at once, if Hushbook is open and unlocked).
// HUSHBOOK_DATA_DIR points it at another diary folder, for testing.

let modernVersions = ["2026-07-28"]
let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let serverInfo: JSON = .object(["name": "hushbook", "title": "Hushbook", "version": "1.0.0"])
let instructions = """
Hushbook is the user's private, encrypted diary. This server is write-only: add_journal_note hands over a note \
(e.g. a transcribed voice recording) and it is sealed immediately; nothing can be read back. The note appears in \
the diary the next time it is unlocked. After a successful call the sender may delete its own copy.
"""

// MARK: - JSON

enum JSON: Codable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - I/O

func send(_ value: JSON) {
    let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? e.encode(value) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func log(_ s: String) { FileHandle.standardError.write(Data("[hushbook-mcp] \(s)\n".utf8)) }

func reply(_ id: JSON, _ result: JSON) { send(.object(["jsonrpc": "2.0", "id": id, "result": result])) }
func fail(_ id: JSON, _ code: Int, _ message: String, data: JSON? = nil) {
    var err: [String: JSON] = ["code": .number(Double(code)), "message": .string(message)]
    if let data { err["data"] = data }
    send(.object(["jsonrpc": "2.0", "id": id, "error": .object(err)]))
}

// MARK: - Store

let root = ProcessInfo.processInfo.environment["HUSHBOOK_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
let store = LocalStore(root: root ?? LocalStore.defaultRoot)

// MARK: - Tool

struct ToolError: Error { let message: String }

let addJournalNote: JSON = .object([
    "name": "add_journal_note",
    "title": "Add journal note",
    "description": .string("""
    Seal a journal note into the user's Hushbook diary. Write-only: the note can't be read back by any tool, and \
    appears in the diary when it is next unlocked. Works while the diary is locked. Returns the note id; on error \
    nothing was stored. Repeating a call with the same external_id returns the same id without adding a duplicate.
    """),
    "inputSchema": .object([
        "type": "object",
        "properties": .object([
            "text": .object(["type": "string", "description": "The note text, e.g. the transcript of a recording. First line becomes the title."]),
            "date": .object(["type": "string", "description": "When it was written or spoken, ISO 8601 (e.g. 2026-10-31T08:15:00+11:00)."]),
            "audio_path": .object(["type": "string", "description": "Absolute path to a recording (m4a, aac, mp3, wav) to attach as a voice note, with text as its transcript. Read during the call; the sender may delete it afterwards."]),
            "latitude": .object(["type": "number"]),
            "longitude": .object(["type": "number"]),
            "external_id": .object(["type": "string", "description": "Sender's idempotency key, e.g. pocket:<id>. Stored only as a hash."]),
            "source": .object(["type": "string", "description": "Where the note came from, e.g. \"Pocket via Jinnie\". Shown as the entry's last line (— source)."]),
        ]),
        "required": .array(["text", "date"]),
        "additionalProperties": false,
    ]),
    "annotations": .object(["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]),
])

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
        f.formatOptions = options
        if let d = f.date(from: s) { return d }
    }
    return nil
}

func addNote(_ args: [String: JSON]) async throws -> JSON {
    guard let text = args["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ToolError(message: "text is required.")
    }
    guard let dateText = args["date"]?.string, let date = parseDate(dateText) else {
        throw ToolError(message: "date is required, as ISO 8601 (e.g. 2026-10-31T08:15:00+11:00).")
    }
    guard store.dropBoxKey() != nil else { throw ToolError(message: Inbox.Failure.notSetUp.description) }
    let externalID = args["external_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    if let externalID, let existing = store.receivedNote(for: externalID) {
        return .object(["id": .string(existing.uuidString), "status": "already_received"])
    }

    var note = QuickNote(date: date, text: text, photos: [])
    if let source = args["source"]?.string, !source.isEmpty { note.text += "\n\n— \(source)" }
    switch (args["latitude"]?.double, args["longitude"]?.double) {
    case let (lat?, lon?):
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { throw ToolError(message: "latitude/longitude out of range.") }
        note.location = EntryLocation(latitude: lat, longitude: lon)   // Hushbook names the place when it imports
    case (nil, nil): break
    default: throw ToolError(message: "Give both latitude and longitude, or neither.")
    }
    if let path = args["audio_path"]?.string, !path.isEmpty {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { throw ToolError(message: "Can't read audio_path \(path).") }
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0 else { throw ToolError(message: "audio_path isn't a playable recording (m4a, aac, mp3 or wav).") }
        note.audio = [QuickNote.Audio(data: data, duration: duration, transcript: text)]
    }

    do { try Inbox.deposit(note, into: store) }
    catch let error as Inbox.Failure { throw ToolError(message: error.description) }
    catch { throw ToolError(message: "Couldn't seal the note: \(error.localizedDescription)") }
    if let externalID { store.markReceived(externalID, note: note.id) }
    return .object(["id": .string(note.id.uuidString), "status": "sealed"])
}

func callTool(_ params: [String: JSON]) async -> JSON {
    guard params["name"]?.string == "add_journal_note" else {
        return .object(["content": .array([.object(["type": "text", "text": .string("Unknown tool \(params["name"]?.string ?? "")")])]), "isError": true])
    }
    do {
        let result = try await addNote(params["arguments"]?.object ?? [:])
        let text = (try? String(decoding: JSONEncoder().encode(result), as: UTF8.self)) ?? "{}"
        return .object(["content": .array([.object(["type": "text", "text": .string(text)])]), "structuredContent": result])
    } catch let error as ToolError {
        return .object(["content": .array([.object(["type": "text", "text": .string(error.message)])]), "isError": true])
    } catch {
        return .object(["content": .array([.object(["type": "text", "text": .string("\(error)")])]), "isError": true])
    }
}

// MARK: - Dispatch

let capabilities: JSON = .object(["tools": .object(["listChanged": false])])

func handle(_ msg: [String: JSON]) async {
    guard let id = msg["id"] else { return }   // notifications (initialized, cancelled, …) need no reply
    let method = msg["method"]?.string ?? ""
    let params = msg["params"]?.object ?? [:]
    let modernVersion = params["_meta"]?.object?["io.modelcontextprotocol/protocolVersion"]?.string

    if let v = modernVersion, !modernVersions.contains(v) {
        fail(id, -32022, "Unsupported protocol version",
             data: .object(["supported": .array((modernVersions + legacyVersions).map(JSON.string)), "requested": .string(v)]))
        return
    }
    func respond(_ result: JSON) {
        if modernVersion != nil, case .object(var o) = result { o["resultType"] = "complete"; reply(id, .object(o)) }
        else { reply(id, result) }
    }

    switch method {
    case "initialize":
        let requested = params["protocolVersion"]?.string ?? legacyVersions[0]
        reply(id, .object(["protocolVersion": .string(legacyVersions.contains(requested) ? requested : legacyVersions[0]),
                           "capabilities": capabilities, "serverInfo": serverInfo, "instructions": .string(instructions)]))
    case "server/discover":
        respond(.object(["supportedVersions": .array((modernVersions + legacyVersions).map(JSON.string)), "capabilities": capabilities,
                         "_meta": .object(["io.modelcontextprotocol/serverInfo": serverInfo]), "instructions": .string(instructions)]))
    case "ping":
        respond(.object([:]))
    case "tools/list":
        respond(.object(["tools": .array([addJournalNote])]))
    case "tools/call":
        respond(await callTool(params))
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}

log("ready (diary \(store.root.path))")
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let msg = try? JSONDecoder().decode(JSON.self, from: Data(line.utf8)).object else {
        fail(.null, -32700, "Parse error")
        continue
    }
    await handle(msg)
}
