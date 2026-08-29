import Foundation
import Security

/// Minimal wrapper for storing agent API keys in the macOS Keychain, keyed by
/// provider name. Keys never go in the plaintext providers file.
enum Keychain {
    private static let service = "com.kitalabs.visor.providerKeys"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func set(_ value: String, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard !value.isEmpty else { return } // empty == clear
        var add = baseQuery(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // Keychain ACLs are bound to the *signature* of the app that created
        // the item. Visor is ad-hoc signed, and an ad-hoc signature is derived
        // from the binary — so every build is a different identity, the ACL
        // never matches, and macOS asks for a password on every launch. That
        // only stops for good with a stable Developer ID signature.
        //
        // Until then, store these items without binding them to an identity
        // that can't stay still. The cost is honest: any process running as
        // this user can read them, where before it was any process plus a
        // password prompt the user was being trained to approve reflexively —
        // which is not a meaningful defence.
        if let access = openAccess(label: "Visor \(account)") {
            add[kSecAttrAccess as String] = access
        }
        SecItemAdd(add as CFDictionary, nil)
    }

    /// A SecAccess whose ACL trusts every application, so no signature has to
    /// match for a read to succeed. Nil on failure, in which case the item is
    /// stored with default (signature-bound) access.
    private static func openAccess(label: String) -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }

        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }

        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess
            else { continue }
            // A nil application list means "any application" — that's the bit
            // that removes the prompt.
            _ = SecACLSetContents(acl, nil, (description ?? label as CFString), prompt)
        }
        return access
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ account: String) -> Bool {
        SecItemCopyMatching(baseQuery(account) as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
