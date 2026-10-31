import Foundation
import CryptoKit

/// Puts notes into the drop box: the Quick Hashnote window and hushbook-mcp both write here. Needs only the drop box
/// public key, never the diary key, so it works while the diary is locked and can't read anything back.
enum Inbox {
    enum Failure: Error, CustomStringConvertible {
        case notSetUp
        var description: String {
            "Hushbook has never been unlocked on this Mac (no drop box key yet). Open Hushbook and unlock it once."
        }
    }

    /// Posted (without any content) after a note is written, so a running, unlocked Hushbook imports it right away.
    static let arrived = Notification.Name("com.romadinov.hushbook.inbox")

    static func deposit(_ note: QuickNote, into store: LocalStore) throws {
        guard let raw = store.dropBoxKey(),
              let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw Failure.notSetUp }
        let sealed = try DropBox.seal(try JSONEncoder().encode(note), to: recipient, id: RecordName.quickNote(note.id))
        store.saveQuickNote(sealed, id: note.id)
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(arrived, object: nil, userInfo: nil, deliverImmediately: true)
        #endif
    }
}
