import Foundation
import Security

/// Where a secret is kept. One method each way, so every platform can satisfy
/// it with whatever its OS provides.
///
/// This exists as a protocol rather than a concrete Keychain type because the
/// same feature has to work on three platforms: macOS and iOS share
/// `KeychainSecretStore` below verbatim — the Security framework API is
/// identical — and the Windows port implements the same two methods over
/// `PasswordVault` or DPAPI. Tests use an in-memory one.
public protocol SecretStoring: Sendable {
    /// The stored secret for `account`, or `nil` when none is stored.
    func read(account: String) throws -> String?
    /// Stores `value`, replacing any existing secret. `nil` removes it.
    func write(_ value: String?, account: String) throws
}

/// The account name the exercise importer's API key is stored under.
public let aiImportKeyAccount = "openai-api-key"

/// Keeps secrets in the login keychain, which is the only place on an Apple
/// platform they belong: encrypted at rest, outside the app's own files, and
/// therefore never picked up by a backup of `data.json` or by the
/// `data.corrupt.json` copy the store writes when it cannot decode.
///
/// Items are `ThisDeviceOnly`, so a key never syncs to iCloud or restores onto
/// a different machine — an API key is cheap to re-enter and expensive to leak.
public struct KeychainSecretStore: SecretStoring {
    /// Namespaces the app's items in a keychain shared with everything else on
    /// the machine.
    public let service: String

    public init(service: String = "com.pauselet.ai-import") {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public func write(_ value: String?, account: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            // Deleting something that was never there is the desired end state.
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(status: status)
            }
            return
        }

        let data = Data(value.utf8)
        // Update in place when an item exists, so the accessibility attribute
        // and any other metadata are not silently reset.
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError(status: status) }

        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError(status: added) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A keychain call failed. Carries the OSStatus so a bug report can say which.
public struct SecretStoreError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        return "Could not reach the keychain (\(detail ?? "error \(status)"))."
    }
}

/// A secret store that keeps nothing, for tests and for previews that must not
/// touch the real keychain.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(_ initial: [String: String] = [:]) { storage = initial }

    public func read(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func write(_ value: String?, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value?.isEmpty == true ? nil : value
    }
}
