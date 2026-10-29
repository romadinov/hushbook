import Foundation
import CryptoKit
import CommonCrypto

/// Public, non-secret description of the diary key: the random 256-bit diary key, sealed with a key derived from
/// the diary password. Synced through iCloud so every device unlocks with the same password.
struct VaultHeader: Codable, Equatable, Sendable {
    var version = 1
    var salt: Data
    var iterations: Int
    var wrappedKey: Data
}

enum DiaryCrypto {
    static let defaultIterations = 600_000   // OWASP 2023 recommendation for PBKDF2-HMAC-SHA256
    private static let wrapAAD = Data("hushbook.vault.v1".utf8)

    static func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let pw = password.precomposedStringWithCanonicalMapping
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuf in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.utf8.count,
                                 saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        defer { _ = out.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: out)
    }

    static func createVault(password: String) throws -> (VaultHeader, SymmetricKey) {
        let key = SymmetricKey(size: .bits256)
        return (try wrap(key, password: password), key)
    }

    static func wrap(_ key: SymmetricKey, password: String) throws -> VaultHeader {
        let salt = randomData(16)
        let kek = deriveKey(password: password, salt: salt, iterations: defaultIterations)
        let sealed = try AES.GCM.seal(key.rawData, using: kek, authenticating: wrapAAD)
        return VaultHeader(salt: salt, iterations: defaultIterations, wrappedKey: sealed.combined!)
    }

    /// Returns nil when the password is wrong.
    static func unwrap(_ header: VaultHeader, password: String) -> SymmetricKey? {
        let kek = deriveKey(password: password, salt: header.salt, iterations: header.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: header.wrappedKey),
              let raw = try? AES.GCM.open(box, using: kek, authenticating: wrapAAD) else { return nil }
        return SymmetricKey(data: raw)
    }

    /// Seals with the record id as associated data, so a blob can't be swapped onto another entry or photo.
    static func seal(_ plain: Data, key: SymmetricKey, id: String) throws -> Data {
        try AES.GCM.seal(plain, using: key, authenticating: Data(id.utf8)).combined!
    }

    static func open(_ sealed: Data, key: SymmetricKey, id: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(id.utf8))
    }

    static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
