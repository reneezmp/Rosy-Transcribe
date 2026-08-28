import Foundation
import Security

/// Stores the API key in the login Keychain.
///
/// v1 kept it in `UserDefaults`, which is a plist in the user's Library that
/// any process running as this user can read. The Keychain is encrypted at
/// rest and gated per-application. For a key attached to a paid account that
/// is worth the extra thirty lines.
///
/// Deliberately tiny: one secret, three operations. No generic wrapper, no
/// property wrapper, nothing to understand six months from now beyond
/// "it reads and writes one string".
enum KeychainStore {

    static let service = "com.rosy.RosyTranscribe"
    static let account = "elevenlabs-api-key"

    /// The service this app used while it was called Scribe Droplet. Anyone
    /// who ran that build has their key filed under this name.
    static let legacyService = "com.rosy.ScribeDroplet"

    /// Key under which v1 stored the API key in UserDefaults.
    static let legacyDefaultsKey = "elevenLabsAPIKey"

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(service: String = service) throws -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func save(_ value: String, service: String = service) throws {
        let data = Data(value.utf8)

        // Update first: the common case after the very first launch.
        let updateStatus = SecItemUpdate(baseQuery(service: service) as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(service: service)
            attributes[kSecValueData as String] = data
            // The key is only needed while the user is using the app, so it
            // does not need to be readable before first unlock.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    static func delete(service: String = service) throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Moves the key across from the name the app used before it was
    /// renamed. Runs before the UserDefaults migration, and only when the
    /// current service holds nothing, so it can never overwrite a newer key.
    @discardableResult
    static func migrateRenamedServiceIfNeeded() -> Bool {
        do {
            guard try read() == nil else { return false }
            guard let inherited = try read(service: legacyService),
                  !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            try save(inherited)
            try delete(service: legacyService)
            return true
        } catch {
            return false
        }
    }

    /// Moves a v1 key out of UserDefaults and into the Keychain, then removes
    /// the plist copy.
    ///
    /// The whole point is deleting that copy, so it only runs once the secret
    /// is provably somewhere else: if the Keychain write fails, the key stays
    /// in UserDefaults rather than being lost.
    @discardableResult
    static func migrateLegacyKeyIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        do {
            // Do not clobber a key already in the Keychain.
            if try read() == nil {
                try save(legacy.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            defaults.removeObject(forKey: legacyDefaultsKey)
            return true
        } catch {
            return false
        }
    }
}

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(detail)"
        }
    }
}
