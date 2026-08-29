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

    /// Rewrite existing items so they stop prompting.
    ///
    /// Storing new keys without a signature-bound ACL fixed nothing for keys
    /// already saved: those items keep the ACL they were created with, and
    /// nothing rewrote them. Every rebuild is a different ad-hoc signature, so
    /// they asked for a password on every launch, forever.
    ///
    /// Reading them here will prompt one last time — clicking "Always Allow"
    /// on that round is the end of it, because what gets written back is
    /// unbound and no future signature can mismatch.
    static func migrateToOpenAccess() {
        let flag = "visor.keychainOpenAccessMigrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        // Mark it done first: if a read hangs or is denied, a half-finished
        // migration shouldn't re-prompt on every subsequent launch too.
        UserDefaults.standard.set(true, forKey: flag)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true

        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return }

        var rewritten = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty
            else { continue }
            set(value, account: account)   // recreates it with open access
            rewritten += 1
        }
        if rewritten > 0 {
            NSLog("[Visor] Rewrote \(rewritten) keychain item(s) so they stop prompting.")
        }
    }
}
