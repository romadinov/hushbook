import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// Remembers the diary key on this device behind Face ID / Touch ID only.
///
/// The Keychain item uses `.biometryCurrentSet`, so:
/// - the device passcode / Mac login password can never release it (no passcode fallback exists for this item);
/// - enrolling a new face or finger (which needs the passcode) destroys it, so the diary password is required again;
/// - it never leaves the device (`ThisDeviceOnly`, not synchronizable) and is gone if the passcode is removed.
/// The expiry date is stored inside the protected value, so it can't be extended without the biometric unlock.
enum BiometricUnlock {
    enum Kind { case none, touchID, faceID, opticID }
    enum Failure: Error { case notRemembered, expired, cancelled, usePassword, unavailable(String) }

    private static let service = "com.romadinov.hushbook.diary-key"
    private static let account = "diary-key"

    static var kind: Kind {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        switch ctx.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    static var kindName: String {
        switch kind {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "Biometrics"
        }
    }

    static var symbol: String {
        switch kind {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .none: "lock"
        }
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    @discardableResult
    static func remember(_ key: SymmetricKey, until: Date) -> Bool {
        forget()
        guard kind != .none,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, nil) else { return false }
        var payload = key.rawData
        withUnsafeBytes(of: until.timeIntervalSince1970.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
        var query = baseQuery()
        query[kSecValueData as String] = payload
        query[kSecAttrAccessControl as String] = access
        // Readable without authentication, for showing the unlock button; the protected value is authoritative.
        query[kSecAttrGeneric as String] = Data(String(until.timeIntervalSince1970).utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Diagnostic: stores and removes a throwaway item with the same protection. Returns the SecItemAdd status.
    static func selfTest() -> (kind: Kind, status: OSStatus) {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, nil) else { return (kind, -1) }
        var query = baseQuery()
        query[kSecAttrAccount as String] = "self-test"
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data([1])
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        query.removeValue(forKey: kSecValueData as String)
        query.removeValue(forKey: kSecAttrAccessControl as String)
        SecItemDelete(query as CFDictionary)
        return (kind, status)
    }

    static func forget() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// Expiry of the remembered key, read without prompting. Nil when nothing is remembered.
    static var rememberedUntil: Date? {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Attributes never need authentication. Don't pass an `interactionNotAllowed` context here: macOS then
        // refuses the lookup with errSecInteractionNotAllowed and the remembered key looks absent.
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any] else { return nil }
        guard let data = attrs[kSecAttrGeneric as String] as? Data,
              let seconds = Double(String(decoding: data, as: UTF8.self)) else { return .distantPast }
        return Date(timeIntervalSince1970: seconds)
    }

    static var canUnlock: Bool {
        guard kind != .none, let until = rememberedUntil else { return false }
        if until < .now { forget(); return false }
        return true
    }

    /// Prompts for Face ID / Touch ID (never the passcode) and returns the remembered diary key.
    static func unlock(reason: String) async -> Result<SymmetricKey, Failure> {
        guard canUnlock else { return .failure(.notRemembered) }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Diary Password"
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
                return .failure(.cancelled)
            }
        } catch let error as LAError {
            switch error.code {
            case .userFallback: return .failure(.usePassword)
            case .userCancel, .appCancel, .systemCancel: return .failure(.cancelled)
            case .biometryLockout:
                // Re-enabling biometrics would need the passcode, which must never open the diary.
                return .failure(.unavailable("\(kindName) is locked after too many attempts. Use the diary password."))
            case .biometryNotEnrolled, .biometryNotAvailable:
                forget()
                return .failure(.unavailable("\(kindName) is not available. Use the diary password."))
            default:
                return .failure(.unavailable(error.localizedDescription))
            }
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = ctx
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 40 else {
            forget()   // e.g. biometrics changed since the key was stored
            return .failure(.notRemembered)
        }
        let bits = data.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let until = Date(timeIntervalSince1970: Double(bitPattern: UInt64(littleEndian: bits)))
        guard until > .now else { forget(); return .failure(.expired) }
        return .success(SymmetricKey(data: data.prefix(32)))
    }
}
