#if canImport(FirebaseCore)
import FirebaseCore
import Foundation

/// Configures Firebase for live note sharing.
///
/// There is intentionally **no Firebase Auth** here. Auth on macOS requires
/// writing to the data-protection keychain, which needs a `keychain-access-groups`
/// entitlement prefixed by a real Team ID — only available with Apple-managed
/// code signing. This app ships ad-hoc signed (Sparkle, no Developer Program), so
/// instead of identity-based access we use a **capability model**: a shared note
/// is reached only via its unguessable id + token (carried in the beam link), and
/// the Firestore rules allow `get`/`write` by id but deny `list`. No auth → no
/// keychain → works on the ad-hoc build.
///
/// Configuration is best-effort: with no `GoogleService-Info.plist` bundled we
/// skip it and the app runs normally with sharing disabled.
enum FirebaseBootstrap {
    private(set) static var configured = false

    /// Configure Firebase. Call once at launch.
    static func start() {
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil else {
            NSLog("[Visor] No GoogleService-Info.plist bundled — live note sharing is disabled.")
            return
        }
        FirebaseApp.configure()
        configured = true
    }
}
#endif
